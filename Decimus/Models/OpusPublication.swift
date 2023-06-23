import Foundation
import AVFAudio
import AVFoundation
import CTPCircularBuffer

class OpusPublication: QPublicationDelegateObjC {
    private let notifier: NotificationCenter = .default

    private var encoder: LibOpusEncoder?
    private unowned let codecFactory: EncoderFactory
    private unowned let publishObjectDelegate: QPublishObjectDelegateObjC
    private unowned let metricsSubmitter: MetricsSubmitter
    private let engine: AVAudioEngine = .init()
    private let buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private var asbd: UnsafePointer<AudioStreamBasicDescription>?
    private var format: AVAudioFormat?
    private var encodeThread: Thread?
    private var converter: AVAudioConverter?
    private var differentEncodeFormat: AVAudioFormat?

    let namespace: QuicrNamespace
    private(set) var capture: PublicationCaptureDelegate?

    init(namespace: QuicrNamespace,
         publishDelegate: QPublishObjectDelegateObjC,
         codecFactory: EncoderFactory,
         metricsSubmitter: MetricsSubmitter) {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.codecFactory = codecFactory
        self.metricsSubmitter = metricsSubmitter
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32 {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        assert(config.codec == .opus)

        do {
            try AVAudioSession.configureForDecimus()
            try engine.inputNode.setVoiceProcessingEnabled(false)
            print(engine.inputNode.outputFormat(forBus: 0))
        } catch {
            fatalError()
        }

        let outputFormat = engine.inputNode.outputFormat(forBus: 0)
        format = outputFormat
        asbd = format!.streamDescription

        let hundredMils = asbd!.pointee.mBytesPerPacket * UInt32(asbd!.pointee.mSampleRate) / 100
        guard _TPCircularBufferInit(buffer, hundredMils, MemoryLayout<TPCircularBuffer>.size) else {
            fatalError()
        }

        do {
            // Try and directly use the microphone output format.
            encoder = try .init(format: outputFormat)
        } catch {
            // Fallback format?
            differentEncodeFormat = .init(commonFormat: outputFormat.commonFormat,
                                          sampleRate: 48000,
                                          channels: 1,
                                          interleaved: true)
            converter = .init(from: outputFormat, to: differentEncodeFormat!)!
            do {
                encoder = try .init(format: differentEncodeFormat!)
            } catch { fatalError() }
        }
        encoder?.registerCallback(callback: { [weak self] data, flag in
            self?.publishObjectDelegate.publishObject(self?.namespace, data: data, group: flag)
        })

        // Start capturing audio.
        let sink: AVAudioSinkNode = .init { [buffer, asbd] timestamp, numFrames, data in
            let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                             data,
                                                             timestamp,
                                                             numFrames,
                                                             asbd)
            guard copied else {
                return 1
            }
            return .zero
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: nil)
        do {
            try engine.start()
        } catch {
            fatalError("\(error)")
        }
        log("Registered \(String(describing: config.codec)) publication for source \(sourceID!)")

        // Start the encode job.
        encodeThread = Thread {
            while true {
                do {
                    try self.encode()
                } catch {
                    print("Encode error: \(error)")
                }
                sleep(.init(0.005))
            }
        }
        encodeThread!.start()
        return PublicationError.None.rawValue
    }

    func encode() throws {
        if let converter = converter {
            let converted: AVAudioPCMBuffer = .init(pcmFormat: differentEncodeFormat!, frameCapacity: 480)!
            var error: NSError? = .init()
            converter.convert(to: converted,
                              error: &error) { [weak self] packets, status in
                guard let self = self else {
                    status.pointee = .endOfStream
                    return nil
                }
                var timestamp: AudioTimeStamp = .init()
                let availableFrames = TPCircularBufferPeek(buffer,
                                                           &timestamp,
                                                           asbd)
                guard availableFrames >= packets else {
                    status.pointee = .noDataNow
                    return .init()
                }

                // We have enough data.
                var inOutFrames: AVAudioFrameCount = packets
                let pcm: AVAudioPCMBuffer = .init(pcmFormat: format!, frameCapacity: packets)!
                pcm.frameLength = packets
                TPCircularBufferDequeueBufferListFrames(buffer,
                                                        &inOutFrames,
                                                        pcm.audioBufferList,
                                                        &timestamp,
                                                        asbd)
                pcm.frameLength = inOutFrames
                guard inOutFrames > 0 else {
                    status.pointee = .noDataNow
                    return .init()
                }
                guard inOutFrames == packets else {
                    print("Dequeue only got: \(inOutFrames)/\(packets)")
                    status.pointee = .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return pcm
            }
            converted.frameLength = 480
            try encoder?.write(data: converted)
            return
        }

        // No conversion.
        let tenMil: AVAudioFrameCount = AVAudioFrameCount(asbd!.pointee.mSampleRate / 100)
        var timestamp: AudioTimeStamp = .init()
        let availableFrames = TPCircularBufferPeek(buffer,
                                                   &timestamp,
                                                   asbd)
        guard availableFrames >= tenMil else { return }

        var inOutFrames: AVAudioFrameCount = tenMil
        let pcm: AVAudioPCMBuffer = .init(pcmFormat: format!, frameCapacity: tenMil)!
        pcm.frameLength = tenMil
        TPCircularBufferDequeueBufferListFrames(buffer,
                                                &inOutFrames,
                                                pcm.audioBufferList,
                                                &timestamp,
                                                asbd)
        pcm.frameLength = inOutFrames
        guard inOutFrames > 0 else { return }
        guard inOutFrames == tenMil else {
            print("Dequeue only got: \(inOutFrames)/\(tenMil)")
            return
        }

        try encoder!.write(data: pcm)
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    func publish(_ flag: Bool) {}

    private func log(_ message: String) {
        print("[Publication] (\(namespace)) \(message)")
    }
}

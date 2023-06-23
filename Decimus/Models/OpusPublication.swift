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
        guard _TPCircularBufferInit(buffer, 1, MemoryLayout<TPCircularBuffer>.size) else {
            fatalError()
        }
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32 {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        guard config.codec == .opus else {
            print("This wasn't opus")
            return PublicationError.None.rawValue
        }
        let outputFormat = engine.inputNode.outputFormat(forBus: 0)
        do {
            // Try and directly use the microphone output format.
            encoder = try .init(format: outputFormat)
            encoder?.registerCallback(callback: { [weak self] data, flag in
                self?.publishObjectDelegate.publishObject(self?.namespace, data: data, group: flag)
            })
            format = outputFormat
        } catch {
            // Fallback format?
            fatalError()
            return PublicationError.FailedEncoderCreation.rawValue
        }
        asbd = format!.streamDescription

        // Start capturing audio.
        do {
            try engine.inputNode.setVoiceProcessingEnabled(false)
        } catch {
            fatalError()
        }

        let sink: AVAudioSinkNode = .init { [buffer, asbd] timestamp, numFrames, data in
            guard data.pointee.mBuffers.mDataByteSize > 0 else {
                fatalError()
            }

            let copied = TPCircularBufferCopyAudioBufferList(buffer, data, timestamp, numFrames, asbd)
            guard copied else {
                print("Didn't copy")
                return 1
            }
            return .zero
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: nil)
        engine.prepare()
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
        let opusFrameSize: AVAudioFrameCount = 480
        var timestamp: AudioTimeStamp = .init()
        let availableFrames = TPCircularBufferPeek(buffer,
                                                   &timestamp,
                                                   asbd)
        guard availableFrames >= opusFrameSize else { return }

        var inOutFrames: AVAudioFrameCount = opusFrameSize
        let pcm: AVAudioPCMBuffer = .init(pcmFormat: format!, frameCapacity: opusFrameSize)!
        pcm.frameLength = opusFrameSize
        TPCircularBufferDequeueBufferListFrames(buffer,
                                                &inOutFrames,
                                                pcm.audioBufferList,
                                                &timestamp,
                                                asbd)
        pcm.frameLength = inOutFrames
        guard inOutFrames > 0 else { return }
        guard inOutFrames == opusFrameSize else {
            print("Dequeue only got: \(inOutFrames)/\(opusFrameSize)")
            return
        }
        try encoder?.write(data: pcm)
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    func publish(_ flag: Bool) {}

    private func log(_ message: String) {
        print("[Publication] (\(namespace)) \(message)")
    }
}

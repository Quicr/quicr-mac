import Foundation
import AVFAudio
import AVFoundation
import CTPCircularBuffer
import CoreAudio

class OpusPublication: Publication {
    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?

    private var encoder: LibOpusEncoder
    private let engine: AVAudioEngine = .init()
    private let buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private var asbd: UnsafePointer<AudioStreamBasicDescription>?
    private var format: AVAudioFormat?
    private var encodeThread: Thread?
    private var converter: AVAudioConverter?
    private var differentEncodeFormat: AVAudioFormat?
    private let metricsSubmitter: MetricsSubmitter

    lazy var block: AVAudioSinkNodeReceiverBlock = { [buffer, asbd] timestamp, numFrames, data in
        // If this is weird multichannel audio, we need to clip.
        // Otherwise, it should be okay.
        if data.pointee.mNumberBuffers > 2 {
            // FIXME: Should we ensure this is always true.
//                let ptr: UnsafeMutableAudioBufferListPointer = .init(.init(mutating: data))
//                var last: UnsafeMutableRawPointer?
//                for list in ptr {
//                    guard last != nil else {
//                        last = list.mData
//                        continue
//                    }
//                    let result = memcmp(last, list.mData, Int(list.mDataByteSize))
//                    last = list.mData
//                    if result != 0 {
//                        fatalError("Mismatch")
//                    }
//                }

            // There's N duplicates of the 1 channel data in here.
            var oneChannelList: AudioBufferList = .init(mNumberBuffers: 1, mBuffers: data.pointee.mBuffers)
            let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                             &oneChannelList,
                                                             timestamp,
                                                             numFrames,
                                                             asbd)
            return copied ? .zero : 1
        } else {
            let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                             data,
                                                             timestamp,
                                                             numFrames,
                                                             asbd)
            return copied ? .zero : 1
        }
    }

    init(namespace: QuicrNamespace,
         publishDelegate: QPublishObjectDelegateObjC,
         sourceID: SourceIDType,
         metricsSubmitter: MetricsSubmitter) {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            fatalError("\(error)")
        }

        do {
            try AVAudioSession.configureForDecimus()
        } catch {
            fatalError()
        }

        let outputFormat = engine.inputNode.outputFormat(forBus: 0)
        if outputFormat.channelCount > 2 {
            // FIXME: For some unknown reason, we can get multichannel duplicate
            // data when using voice processing. All channels appear to be the same,
            // so we clip to mono.
            var oneChannelAsbd = outputFormat.streamDescription.pointee
            oneChannelAsbd.mChannelsPerFrame = 1
            format = .init(streamDescription: &oneChannelAsbd)
        } else {
            format = outputFormat
        }
        asbd = format!.streamDescription

        // Create a buffer to hold raw data waiting for encode.
        let hundredMils = asbd!.pointee.mBytesPerPacket * UInt32(asbd!.pointee.mSampleRate) / 100
        guard _TPCircularBufferInit(buffer, hundredMils, MemoryLayout<TPCircularBuffer>.size) else {
            fatalError()
        }

        do {
            // Try and directly use the microphone output format.
            encoder = try .init(format: format!)
            log("Encoder created using native format: \(format!)")
        } catch {
            // We need to fallback to an opus supported format if we can.
            let sampleRate: Double = Self.isNativeOpusSampleRate(format!.sampleRate) ? format!.sampleRate : .opus48khz
            differentEncodeFormat = .init(commonFormat: format!.commonFormat,
                                          sampleRate: sampleRate,
                                          channels: format!.channelCount,
                                          interleaved: true)
            converter = .init(from: format!, to: differentEncodeFormat!)!
            do {
                encoder = try .init(format: differentEncodeFormat!)
                log("Encoder created using fallback format: \(differentEncodeFormat!)")
            } catch { fatalError() }
        }
        encoder.registerCallback(callback: { [weak self] data, flag in
            self?.publishObjectDelegate?.publishObject(self?.namespace, data: data, group: flag)
        })

        // Start capturing audio.
        let sink: AVAudioSinkNode = .init(receiverBlock: block)
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: nil)
        do {
            try engine.start()
        } catch {
            fatalError("\(error)")
        }
        log("Registered OPUS publication for source \(sourceID)")
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32 {
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

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    private func encode() throws {
        guard converter == nil else {
            try convertAndEncode(converter: converter!, to: differentEncodeFormat!, from: format!)
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

        try encoder.write(data: pcm)
    }

    // swiftlint:disable identifier_name
    private func convertAndEncode(converter: AVAudioConverter,
                                  to: AVAudioFormat,
                                  from: AVAudioFormat) throws {
        // Is it a trivial conversion?
        if to.commonFormat == from.commonFormat &&
            to.sampleRate == from.sampleRate {
            try trivialConvertAndEncode(converter: converter, to: to, from: from)
            return
        }

        let converted: AVAudioPCMBuffer = .init(pcmFormat: to, frameCapacity: 480)!
        var error: NSError? = .init()
        converter.convert(to: converted,
                          error: &error) { [weak self] packets, status in
            guard let self = self else {
                status.pointee = .endOfStream
                return nil
            }
            var timestamp: AudioTimeStamp = .init()
            let availableFrames = TPCircularBufferPeek(self.buffer,
                                                       &timestamp,
                                                       from.streamDescription)
            guard availableFrames >= packets else {
                status.pointee = .noDataNow
                return .init()
            }

            // We have enough data.
            var inOutFrames: AVAudioFrameCount = packets
            let pcm: AVAudioPCMBuffer = .init(pcmFormat: self.format!, frameCapacity: packets)!
            pcm.frameLength = packets
            TPCircularBufferDequeueBufferListFrames(self.buffer,
                                                    &inOutFrames,
                                                    pcm.audioBufferList,
                                                    &timestamp,
                                                    from.streamDescription)
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
        try encoder.write(data: converted)
        return
    }

    private func trivialConvertAndEncode(converter: AVAudioConverter,
                                         to: AVAudioFormat,
                                         from: AVAudioFormat) throws {
            // Target encode size.
            var inOutFrames: AVAudioFrameCount = 480

            // Are there enough frames for an encode?
            let availableFrames = TPCircularBufferPeek(self.buffer,
                                                       nil,
                                                       from.streamDescription)
            guard availableFrames >= inOutFrames else {
                return
            }

            // Data holders.
            let dequeued: AVAudioPCMBuffer = .init(pcmFormat: from,
                                                   frameCapacity: inOutFrames)!
            dequeued.frameLength = inOutFrames
            let converted: AVAudioPCMBuffer = .init(pcmFormat: to,
                                                    frameCapacity: inOutFrames)!
            converted.frameLength = inOutFrames

            // Get some data to encode.
            TPCircularBufferDequeueBufferListFrames(self.buffer,
                                                    &inOutFrames,
                                                    dequeued.audioBufferList,
                                                    nil,
                                                    from.streamDescription)
            dequeued.frameLength = inOutFrames
            converted.frameLength = inOutFrames

            // Convert and encode.
            try converter.convert(to: converted, from: dequeued)
            try encoder.write(data: converted)
            return
    }

    func publish(_ flag: Bool) {}

    private static func isNativeOpusSampleRate(_ sampleRate: Double) -> Bool {
        switch sampleRate {
        case .opus48khz, .opus24khz, .opus12khz, .opus16khz, .opus8khz:
            return true
        default:
            return false
        }
    }
}

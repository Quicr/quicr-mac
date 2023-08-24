import Foundation
import AVFAudio
import AVFoundation
import CTPCircularBuffer
import CoreAudio

class OpusPublication: Publication {
    private actor _Measurement: Measurement {
        var name: String = "OpusPublication"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0

        init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
            tags["namespace"] = namespace
            Task {
                await submitter.register(measurement: self)
            }
        }

        func publishedBytes(sentBytes: Int, timestamp: Date?) {
            self.frames += 1
            self.bytes += UInt64(sentBytes)
            record(field: "publishedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
            record(field: "publishedFrames", value: self.frames as AnyObject, timestamp: timestamp)
        }
    }

    let namespace: QuicrNamespace
    internal weak var publishObjectDelegate: QPublishObjectDelegateObjC?

    private var encoder: LibOpusEncoder
    private let engine: AVAudioEngine = .init()
    private let buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var differentEncodeFormat: AVAudioFormat?
    private let errorWriter: ErrorWriter
    private var encodeTimer: Timer?
    private let measurement: _Measurement?
    private let opusWindowSize: TimeInterval
    private let reliable: Bool

    lazy var block: AVAudioSinkNodeReceiverBlock = { [buffer, format] timestamp, numFrames, data in
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
                                                             format.streamDescription)
            return copied ? .zero : 1
        } else {
            let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                             data,
                                                             timestamp,
                                                             numFrames,
                                                             format.streamDescription)
            return copied ? .zero : 1
        }
    }

    private lazy var encodeBlock: (Timer) -> Void = { [weak self] _ in
        DispatchQueue.global(qos: .userInteractive).async {
            guard let self = self else { return }
            do {
                try self.encode()
            } catch {
                self.log("Failed encode: \(error)")
            }
        }
    }

    init(namespace: QuicrNamespace,
         publishDelegate: QPublishObjectDelegateObjC,
         sourceID: SourceIDType,
         metricsSubmitter: MetricsSubmitter?,
         errorWriter: ErrorWriter,
         opusWindowSize: TimeInterval,
         reliable: Bool) throws {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.errorWriter = errorWriter
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable

        let outputFormat = engine.inputNode.outputFormat(forBus: 0)
        if outputFormat.channelCount > 2 {
            // FIXME: For some unknown reason, we can get multichannel duplicate
            // data when using voice processing. All channels appear to be the same,
            // so we clip to mono.
            var oneChannelAsbd = outputFormat.streamDescription.pointee
            oneChannelAsbd.mChannelsPerFrame = 1
            format = .init(streamDescription: &oneChannelAsbd)!
        } else {
            format = outputFormat
        }

        guard format.sampleRate > 0 else {
            throw "Invalid input format"
        }

        // Create a buffer to hold raw data waiting for encode.
        let hundredMils = Double(format.streamDescription.pointee.mBytesPerPacket) * format.sampleRate * opusWindowSize
        guard _TPCircularBufferInit(buffer, UInt32(hundredMils), MemoryLayout<TPCircularBuffer>.size) else {
            fatalError()
        }

        do {
            // Try and directly use the microphone output format.
            encoder = try .init(format: format)
            log("Encoder created using native format: \(format)")
        } catch {
            // We need to fallback to an opus supported format if we can.
            let sampleRate: Double = Self.isNativeOpusSampleRate(format.sampleRate) ? format.sampleRate : .opus48khz
            differentEncodeFormat = .init(commonFormat: format.commonFormat,
                                          sampleRate: sampleRate,
                                          channels: format.channelCount,
                                          interleaved: true)
            converter = .init(from: format, to: differentEncodeFormat!)!
            encoder = try .init(format: differentEncodeFormat!)
            log("Encoder created using fallback format: \(differentEncodeFormat!)")
        }
        encoder.registerCallback(callback: { [weak self] data, datalength, flag in
            guard let self = self else { return }
            if let measurement = measurement {
                Task(priority: .utility) {
                    await measurement.publishedBytes(sentBytes: datalength, timestamp: nil)
                }
            }
            self.publishObjectDelegate?.publishObject(self.namespace, data: data, length: datalength, group: flag)
        })

        // Encode job: timer procs on main thread, but encoding itself isn't.
        DispatchQueue.main.async {
            self.encodeTimer = .scheduledTimer(withTimeInterval: opusWindowSize,
                                               repeats: true,
                                               block: self.encodeBlock)
            self.encodeTimer!.tolerance = opusWindowSize / 2
        }

        // Start capturing audio.
        let sink: AVAudioSinkNode = .init(receiverBlock: block)
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: nil)
        try engine.start()
        log("Registered OPUS publication for source \(sourceID)")
    }

    deinit {
        encodeTimer?.invalidate()
        TPCircularBufferCleanup(self.buffer)
        log("deinit")
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!, reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    private func encode() throws {
        guard converter == nil else {
            let data = try convertAndEncode(converter: converter!, to: differentEncodeFormat!, from: format)
            guard let data = data else { return }
            try encoder.write(data: data)
            return
        }

        // No conversion.
        let windowFrames: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate * self.opusWindowSize)
        var timestamp: AudioTimeStamp = .init()
        let availableFrames = TPCircularBufferPeek(buffer,
                                                   &timestamp,
                                                   format.streamDescription)
        guard availableFrames >= windowFrames else { return }

        let pcm: AVAudioPCMBuffer = .init(pcmFormat: format, frameCapacity: windowFrames)!
        pcm.frameLength = windowFrames
        var inOutFrames: AVAudioFrameCount = windowFrames
        TPCircularBufferDequeueBufferListFrames(buffer,
                                                &inOutFrames,
                                                pcm.audioBufferList,
                                                &timestamp,
                                                format.streamDescription)
        pcm.frameLength = inOutFrames
        guard inOutFrames > 0 else { return }
        guard inOutFrames == windowFrames else {
            log("Dequeue only got: \(inOutFrames)/\(windowFrames)")
            return
        }

        try encoder.write(data: pcm)
    }

    // swiftlint:disable identifier_name
    private func convertAndEncode(converter: AVAudioConverter,
                                  to: AVAudioFormat,
                                  from: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        // Is it a trivial conversion?
        if to.commonFormat == from.commonFormat &&
            to.sampleRate == from.sampleRate {
            return try trivialConvertAndEncode(converter: converter, to: to, from: from)
        }

        let windowFrames: AVAudioFrameCount = .init(to.sampleRate * self.opusWindowSize)
        let converted: AVAudioPCMBuffer = .init(pcmFormat: to, frameCapacity: windowFrames)!
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
            let pcm: AVAudioPCMBuffer = .init(pcmFormat: from, frameCapacity: packets)!
            pcm.frameLength = packets
            TPCircularBufferDequeueBufferListFrames(self.buffer,
                                                    &inOutFrames,
                                                    pcm.audioBufferList,
                                                    &timestamp,
                                                    from.streamDescription)
            assert(inOutFrames == packets)
            pcm.frameLength = inOutFrames
            status.pointee = .haveData
            return pcm
        }
        return converted.frameLength > 0 ? converted : nil
    }

    private func trivialConvertAndEncode(converter: AVAudioConverter,
                                         to: AVAudioFormat,
                                         from: AVAudioFormat) throws -> AVAudioPCMBuffer? {
            // Target encode size.
            var inOutFrames: AVAudioFrameCount = .init(format.sampleRate * self.opusWindowSize)

            // Are there enough frames for an encode?
            let availableFrames = TPCircularBufferPeek(self.buffer,
                                                       nil,
                                                       from.streamDescription)
            guard availableFrames >= inOutFrames else {
                return nil
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
            return converted
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

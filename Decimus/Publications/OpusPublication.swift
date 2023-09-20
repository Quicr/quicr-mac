import Foundation
import AVFAudio
import AVFoundation
import CTPCircularBuffer
import CoreAudio
import os

class OpusPublication: Hashable, Publication {
    static func == (lhs: OpusPublication, rhs: OpusPublication) -> Bool {
        lhs.namespace == rhs.namespace
    }

    private static let logger = DecimusLogger(OpusPublication.self)

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

    private var encoder: LibOpusEncoder?
    private let buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var differentEncodeFormat: AVAudioFormat?
    private var encodeTimer: Timer?
    private let measurement: _Measurement?
    private let opusWindowSize: OpusWindowSize
    private let reliable: Bool
    private let granularMetrics: Bool
    private unowned let engine: AudioEngine
    private let reconfig: Wrapped<Bool> = .init(false)

    lazy var block: AVAudioSinkNodeReceiverBlock = { [buffer, format, reconfig] timestamp, numFrames, data in
        assert(!reconfig.value)
        assert(data.pointee.mNumberBuffers <= 2)
        let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                         data,
                                                         timestamp,
                                                         numFrames,
                                                         format!.streamDescription)
        return copied ? .zero : 1
    }

    private lazy var encodeBlock: (Timer) -> Void = { [weak self] _ in
        DispatchQueue.global(qos: .userInteractive).async {
            guard let self = self else { return }
            assert(!self.reconfig.value)
            do {
                while let data = try self.encode() {
                    self.publish(data: data)
                }
            } catch {
                Self.logger.error("Failed encode: \(error)")
            }
        }
    }

    init(namespace: QuicrNamespace,
         publishDelegate: QPublishObjectDelegateObjC,
         sourceID: SourceIDType,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         engine: AudioEngine,
         granularMetrics: Bool) throws {
        self.namespace = namespace
        self.publishObjectDelegate = publishDelegate
        self.engine = engine
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics

        // Configure opus encoder.
        try _reconfigure()

        // Register our block.
        engine.registerSinkBlock(block)
        engine.registerReconfigureInterest(id: self, callback: reconfigure)
        Self.logger.info("Registered OPUS publication for source \(sourceID)")
    }

    deinit {
        encodeTimer?.invalidate()
        TPCircularBufferCleanup(self.buffer)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(namespace)
    }

    private func _reconfigure() throws {
        // Reconfigure the opus encoder based on the input format.
        guard engine.inputFormat.sampleRate > 0 else { throw "Invalid input format" }
        let format = engine.inputFormat
        Self.logger.info("Reconfiguring: \(format)")

        if format != self.format {
            if self.format != nil {
                // Additional explicit cleanup.
                self.reconfig.value = true
                DispatchQueue.main.async {
                    self.encodeTimer!.invalidate()
                }
                TPCircularBufferCleanup(buffer)
                Self.logger.info("Stopped the timer, flushed the buffer")
            }

            // Create a buffer to hold raw data waiting for encode.
            let hundredMils = Double(format.streamDescription.pointee.mBytesPerPacket) * format.sampleRate * opusWindowSize.rawValue
            guard _TPCircularBufferInit(buffer, UInt32(hundredMils), MemoryLayout<TPCircularBuffer>.size) else {
                fatalError()
            }

            // Make an opus encoder.
            var encoder: LibOpusEncoder
            do {
                // Try and directly use the microphone output format.
                encoder = try .init(format: format, desiredWindowSize: opusWindowSize)
                Self.logger.info("Encoder created using native format: \(format)")
            } catch {
                // We need to fallback to an opus supported format if we can.
                let sampleRate: Double = Self.isNativeOpusSampleRate(format.sampleRate) ? format.sampleRate : .opus48khz
                differentEncodeFormat = .init(commonFormat: format.commonFormat,
                                              sampleRate: sampleRate,
                                              channels: format.channelCount,
                                              interleaved: true)
                converter = .init(from: format, to: differentEncodeFormat!)!
                encoder = try .init(format: differentEncodeFormat!, desiredWindowSize: opusWindowSize)
                Self.logger.info("Encoder created using fallback format: \(self.differentEncodeFormat!)")
            }

            // Done.
            self.encoder = encoder
            self.format = format
            self.reconfig.value = false
        }

        // Start encode job: timer procs on main thread, but encoding itself isn't.
        if self.encodeTimer == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.encodeTimer = .scheduledTimer(withTimeInterval: self.opusWindowSize.rawValue,
                                                   repeats: true,
                                                   block: self.encodeBlock)
                self.encodeTimer!.tolerance = self.opusWindowSize.rawValue / 2
            }
        }

        Self.logger.info("Finished reconfiguring")
    }

    func reconfigure() {
        do {
            try _reconfigure()
        } catch {
            Self.logger.error(error.localizedDescription)
        }
    }

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!, reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return PublicationError.None.rawValue
    }

    func update(_ sourceId: String!, qualityProfile: String!) -> Int32 {
        return PublicationError.NoSource.rawValue
    }

    private func publish(data: Data) {
        if let measurement = self.measurement {
            let now: Date? = granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.publishedBytes(sentBytes: data.count, timestamp: now)
            }
        }
        self.publishObjectDelegate?.publishObject(self.namespace, data: data, group: true)
    }

    private func encode() throws -> Data? {
        guard let format = self.format else { throw "Missing expected format" }

        guard converter == nil else {
            let data = try convert(converter: converter!, to: differentEncodeFormat!, from: format)
            guard let data = data else { return nil }
            guard let encoder = self.encoder else { throw "Missing expected encoder" }
            return try encoder.write(data: data)
        }

        // No conversion.
        let windowFrames: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate * self.opusWindowSize.rawValue)
        var timestamp: AudioTimeStamp = .init()
        let availableFrames = TPCircularBufferPeek(buffer,
                                                   &timestamp,
                                                   format.streamDescription)
        guard availableFrames >= windowFrames else { return nil }

        let pcm: AVAudioPCMBuffer = .init(pcmFormat: format, frameCapacity: windowFrames)!
        pcm.frameLength = windowFrames
        var inOutFrames: AVAudioFrameCount = windowFrames
        TPCircularBufferDequeueBufferListFrames(buffer,
                                                &inOutFrames,
                                                pcm.audioBufferList,
                                                &timestamp,
                                                format.streamDescription)
        pcm.frameLength = inOutFrames
        guard inOutFrames == windowFrames else {
            Self.logger.info("Dequeue only got: \(inOutFrames)/\(windowFrames)")
            return nil
        }

        guard let encoder = self.encoder else { throw "Missing expected encoder" }
        return try encoder.write(data: pcm)
    }

    // swiftlint:disable identifier_name
    private func convert(converter: AVAudioConverter,
                         to: AVAudioFormat,
                         from: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        // Is it a trivial conversion?
        if to.commonFormat == from.commonFormat &&
            to.sampleRate == from.sampleRate {
            return try trivialConvert(converter: converter, to: to, from: from)
        }

        let windowFrames: AVAudioFrameCount = .init(to.sampleRate * self.opusWindowSize.rawValue)
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

    private func trivialConvert(converter: AVAudioConverter,
                                to: AVAudioFormat,
                                from: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard let format = self.format else { throw "Missing expected format" }
        
        // Target encode size.
        var inOutFrames: AVAudioFrameCount = .init(format.sampleRate * self.opusWindowSize.rawValue)

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

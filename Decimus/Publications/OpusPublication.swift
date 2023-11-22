import Foundation
import AVFAudio
import AVFoundation
import CTPCircularBuffer
import CoreAudio
import os

class OpusPublication: Publication {
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

    private let encoder: LibOpusEncoder
    private let buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private var encodeTimer: Timer?
    private let measurement: _Measurement?
    private let opusWindowSize: OpusWindowSize
    private let reliable: Bool
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine

    lazy var block: AVAudioSinkNodeReceiverBlock = { [buffer] timestamp, numFrames, data in
        assert(data.pointee.mNumberBuffers <= 2)
        let copied = TPCircularBufferCopyAudioBufferList(buffer,
                                                         data,
                                                         timestamp,
                                                         numFrames,
                                                         DecimusAudioEngine.format.streamDescription)
        return copied ? .zero : 1
    }

    private lazy var encodeBlock: (Timer) -> Void = { [weak self] _ in
        DispatchQueue.global(qos: .userInteractive).async {
            guard let self = self else { return }
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
         engine: DecimusAudioEngine,
         granularMetrics: Bool,
         config: AudioCodecConfig) throws {
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

        // Create a buffer to hold raw data waiting for encode.
        let format = DecimusAudioEngine.format
        let hundredMils = Double(format.streamDescription.pointee.mBytesPerPacket) * format.sampleRate * opusWindowSize.rawValue
        guard _TPCircularBufferInit(buffer, UInt32(hundredMils), MemoryLayout<TPCircularBuffer>.size) else {
            fatalError()
        }

        encoder = try .init(format: format, desiredWindowSize: opusWindowSize, bitrate: Int(config.bitrate))
        Self.logger.info("Created Opus Encoder")

        // TODO: Move to concurrency.
        // Encode job: timer procs on main thread, but encoding itself doesn't.
        DispatchQueue.main.async {
            self.encodeTimer = .scheduledTimer(withTimeInterval: opusWindowSize.rawValue,
                                               repeats: true,
                                               block: self.encodeBlock)
            self.encodeTimer!.tolerance = opusWindowSize.rawValue / 2
        }

        // Register our block.
        try engine.registerSinkBlock(identifier: namespace, block: block)
        Self.logger.info("Registered OPUS publication for source \(sourceID)")
    }

    deinit {
        do {
            try engine.unregisterSinkBlock(identifier: self.namespace)
        } catch {
            Self.logger.critical("Failed to unregister sink block: \(error.localizedDescription)")
        }
        encodeTimer?.invalidate()
        TPCircularBufferCleanup(self.buffer)
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
        let format = DecimusAudioEngine.format
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

        return try encoder.write(data: pcm)
    }

    func publish(_ flag: Bool) {}
}

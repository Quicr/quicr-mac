// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import CoreAudio
import Synchronization

enum OpusSubscriptionError: Error {
    case failedDecoderCreation
}

class OpusHandler: TimeAlignable, TimeAlignerSet {
    // swiftlint:disable:this type_body_length
    private static let logger = DecimusLogger(OpusHandler.self)
    private let identifier: String
    private var decoder: LibOpusDecoder
    private let engine: DecimusAudioEngine
    private let asbd: UnsafeMutablePointer<AudioStreamBasicDescription>
    private var node: AVAudioSourceNode?
    private var oldJitterBuffer: QJitterBuffer?
    private let useNewJitterBuffer: Bool
    private var playoutBuffer: CircularBuffer?
    private let measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?
    private let underrun = Atomic<UInt64>(0)
    private let callbacks = Atomic<UInt64>(0)
    private let granularMetrics: Bool
    private var dequeueTask: Task<Void, Never>?
    private var lastUsedSequence: UInt64?
    private let windowSizeUs = Atomic<UInt32>(0)
    private var windowSize: OpusWindowSize?
    private let metricsSubmitter: MetricsSubmitter?
    private let jitterDepth: TimeInterval
    private let jitterMax: TimeInterval
    private let playing: Atomic<Bool> = .init(false)

    // Time based buffer.
    private var timeAligner: TimeAligner?
    var alignables: [TimeAlignable] { [self] }

    /// Audio data to be emplaced into the jitter buffer.
    private class AudioJitterItem: JitterBuffer.JitterItem {
        /// Encoded opus data.
        let data: Data
        /// Sequence number of this opus packet.
        let sequenceNumber: UInt64
        /// Capture timestamp of this audio (first frame's time).
        let timestamp: CMTime

        init(data: Data, sequenceNumber: UInt64, timestamp: CMTime) {
            self.data = data
            self.sequenceNumber = sequenceNumber
            self.timestamp = timestamp
        }
    }

    init(identifier: String,
         engine: DecimusAudioEngine,
         measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         granularMetrics: Bool,
         useNewJitterBuffer: Bool,
         metricsSubmitter: MetricsSubmitter?) throws {
        self.identifier = identifier
        self.engine = engine
        self.measurement = measurement
        self.granularMetrics = granularMetrics
        self.decoder = try .init(format: DecimusAudioEngine.format)
        self.asbd = .init(mutating: decoder.decodedFormat.streamDescription)
        self.useNewJitterBuffer = useNewJitterBuffer
        self.metricsSubmitter = metricsSubmitter
        self.jitterDepth = jitterDepth
        self.jitterMax = jitterMax
        super.init()
        if !self.useNewJitterBuffer {
            // Create the jitter buffer.
            let opusPacketSize = self.asbd.pointee.mSampleRate * opusWindowSize.rawValue
            self.oldJitterBuffer = QJitterBuffer(elementSize: Int(asbd.pointee.mBytesPerPacket),
                                                 packetElements: Int(opusPacketSize),
                                                 clockRate: UInt(asbd.pointee.mSampleRate),
                                                 maxLengthMs: UInt(jitterMax * 1000),
                                                 minLengthMs: UInt(jitterDepth * 1000)) { level, msg, alert in
                OpusHandler.logger.log(level: DecimusLogger.LogLevel(rawValue: level)!, msg!, alert: alert)
            }
            // Create the player node.
            self.node = .init(format: self.decoder.decodedFormat, renderBlock: self.renderBlock)
            let node = AVAudioSourceNode(format: self.decoder.decodedFormat, renderBlock: self.renderBlock)
            self.node = node
            try self.engine.addPlayer(identifier: identifier, node: node)
            self.jitterBuffer = nil
        }
    }

    deinit {
        // Remove the audio playout.
        do {
            try engine.removePlayer(identifier: self.identifier)
        } catch {
            Self.logger.error("Couldn't remove player: \(error.localizedDescription)")
        }

        // Reset the node.
        node?.reset()
    }

    func createNewJitterBuffer(windowDuration: CMTime) throws -> JitterBuffer {
        guard self.useNewJitterBuffer else { throw "Configuration Issue" }
        // swiftlint:disable force_cast
        let handlers = CMBufferQueue.Handlers { builder in
            builder.compare {
                let first = $0 as! AudioJitterItem
                let second = $1 as! AudioJitterItem
                let seq1 = first.sequenceNumber
                let seq2 = second.sequenceNumber
                if seq1 < seq2 {
                    return .compareLessThan
                } else if seq1 > seq2 {
                    return .compareGreaterThan
                } else if seq1 == seq2 {
                    return .compareEqualTo
                }
                assert(false)
                return .compareLessThan
            }
            builder.getDecodeTimeStamp {
                ($0 as! AudioJitterItem).timestamp
            }
            builder.getDuration { _ in
                windowDuration
            }
            builder.getPresentationTimeStamp {
                ($0 as! AudioJitterItem).timestamp
            }
            builder.getSize {
                ($0 as! AudioJitterItem).data.count
            }
            builder.isDataReady { _ in
                true
            }
        }
        // swiftlint:enable force_cast
        let buffer = try JitterBuffer(identifier: self.identifier,
                                      metricsSubmitter: self.metricsSubmitter,
                                      minDepth: self.jitterDepth,
                                      capacity: Int(self.jitterMax / windowDuration.seconds),
                                      handlers: handlers)
        self.jitterBuffer = buffer

        // TODO: Config for these constants.
        let format = DecimusAudioEngine.format
        let playoutLengthTime: TimeInterval = 0.05
        let playoutLength = UInt32(format.sampleRate * Double(format.streamDescription.pointee.mBytesPerFrame) * playoutLengthTime)
        self.playoutBuffer = try .init(length: playoutLength,
                                       format: self.asbd.pointee)
        let slidingWindowLength: TimeInterval = 5.0
        let capacity = Int(slidingWindowLength * (1.0/0.02)) // TODO: Window Size.
        self.timeAligner = .init(windowLength: slidingWindowLength, capacity: capacity, set: self)
        self.createDequeueTask()
        // Create the player node.
        let node = AVAudioSourceNode(format: self.decoder.decodedFormat, renderBlock: self.renderBlock)
        self.node = node
        try self.engine.addPlayer(identifier: self.identifier, node: node)
        return buffer
    }

    func submitEncodedAudio(data: Data, sequence: UInt64, date: Date, timestamp: Date) throws {
        if self.useNewJitterBuffer {
            let jitterBuffer: JitterBuffer
            if let existing = self.jitterBuffer {
                jitterBuffer = existing
            } else {
                // What's the duration of this packet?
                let frames = try self.decoder.frames(data: data)
                let duration = TimeInterval(frames) / 48000.0 // TODO: Sample rate?
                let durationUs = duration * microsecondsPerSecond
                let cmDuration = CMTime(value: CMTimeValue(durationUs), timescale: CMTimeScale(microsecondsPerSecond))
                // Create jitter buffer.
                jitterBuffer = try self.createNewJitterBuffer(windowDuration: cmDuration)
            }

            // Set the timestamp diff from the first recveived object.
            self.timeAligner!.doTimestampTimeDiff(timestamp.timeIntervalSince1970, when: date)

            // TODO: Is this right?
            // We don't want to emplace this if we're not playing out yet.
            guard self.playing.load(ordering: .acquiring) else { return }

            // Emplace this encoded data into the jitter buffer.
            let usSinceEpoch = timestamp.timeIntervalSince1970 * microsecondsPerSecond
            let timestamp = CMTime(value: CMTimeValue(usSinceEpoch), timescale: CMTimeScale(microsecondsPerSecond))
            let item = AudioJitterItem(data: data, sequenceNumber: sequence, timestamp: timestamp)
            do {
                try jitterBuffer.write(item: item, from: date)
            } catch JitterBufferError.full {
                Self.logger.warning("Didn't enqueue audio as jitter buffer is full")
            } catch JitterBufferError.old {
                Self.logger.warning("Didn't enqueue audio as already concealed / used")
            }
            return
        }

        // Generate PLC prior to real decode.
        guard let jitterBuffer = self.oldJitterBuffer else {
            throw "Invalid Jitter Buffer State"
        }
        let selfPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        jitterBuffer.prepare(UInt(sequence),
                             concealmentCallback: self.plcCallback,
                             userData: selfPtr)

        // Decode and queue for playout.
        let decoded = try decoder.write(data: data)
        try self.queueDecodedAudio(buffer: decoded, timestamp: date, sequence: sequence)

        // Metrics.
        let metricsDate = self.granularMetrics ? date : nil
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.framesUnderrun(underrun: self.underrun.load(ordering: .relaxed),
                                                             timestamp: metricsDate)
                await measurement.measurement.callbacks(callbacks: self.callbacks.load(ordering: .relaxed),
                                                        timestamp: metricsDate)
                if let metricsDate = metricsDate {
                    await measurement.measurement.depth(depthMs: jitterBuffer.getCurrentDepth(),
                                                        timestamp: metricsDate)
                }
            }
        }
    }

    private lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [weak self] silence, _, numFrames, data in
        guard let self = self else { return .zero }
        self.playing.store(true, ordering: .releasing)
        // Fill the buffers as best we can.
        self.callbacks.wrappingAdd(UInt64(numFrames), ordering: .relaxed)
        guard data.pointee.mNumberBuffers == 1 else {
            // Unexpected.
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            Self.logger.error("Got multiple buffers: \(data.pointee.mNumberBuffers)")
            for (idx, buffer) in buffers.enumerated() {
                Self.logger.error("Buffer \(idx) size: \(buffer.mDataByteSize), channels: \(buffer.mNumberChannels)")
            }
            return 1
        }

        guard data.pointee.mBuffers.mNumberChannels == self.asbd.pointee.mChannelsPerFrame else {
            Self.logger.error("Unexpected render block channels. Got \(data.pointee.mBuffers.mNumberChannels). Expected \(self.asbd.pointee.mChannelsPerFrame)")
            return 1
        }

        let buffer: AudioBuffer = data.pointee.mBuffers
        assert(buffer.mDataByteSize == numFrames * self.asbd.pointee.mBytesPerFrame)

        let copiedFrames: Int
        if let playoutBuffer = self.playoutBuffer {
            let result = playoutBuffer.dequeue(frames: numFrames, buffer: &data.pointee)
            copiedFrames = Int(result.frames)
        } else if let jitterBuffer = self.oldJitterBuffer {
            copiedFrames = jitterBuffer.dequeue(buffer.mData,
                                                destinationLength: Int(buffer.mDataByteSize),
                                                elements: Int(numFrames))
        } else {
            copiedFrames = 0
        }
        guard copiedFrames == numFrames else {
            // Ensure any incomplete data is pure silence.
            let framesUnderan = UInt64(numFrames) - UInt64(copiedFrames)
            silence.pointee = .init(framesUnderan == numFrames)
            self.underrun.wrappingAdd(framesUnderan, ordering: .relaxed)
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            for buffer in buffers {
                guard let dataPointer = buffer.mData else {
                    break
                }
                let bytesPerFrame = Int(self.asbd.pointee.mBytesPerFrame)
                let discontinuityStartOffset = copiedFrames * bytesPerFrame
                let numberOfSilenceBytes = Int(framesUnderan) * bytesPerFrame
                guard discontinuityStartOffset + numberOfSilenceBytes == buffer.mDataByteSize else {
                    Self.logger.error("Invalid buffers when calculating silence")
                    break
                }
                memset(dataPointer + discontinuityStartOffset, 0, Int(numberOfSilenceBytes))
            }
            return .zero
        }
        return .zero
    }

    private let plcCallback: PacketCallback = { packets, count, userData in
        guard let userData = userData else {
            OpusHandler.logger.error("Expected self in userData")
            return
        }
        let handler: OpusHandler = Unmanaged<OpusHandler>.fromOpaque(userData).takeUnretainedValue()
        var concealed: UInt64 = 0
        for index in 0..<count {
            // Make PLC packets.
            var packet = packets!.advanced(by: index)
            do {
                // TODO: This can be optimized with some further work to decode PLC directly into the buffer.
                let plcData = try handler.decoder.plc(frames: AVAudioFrameCount(packet.pointee.elements))
                let list = plcData.audioBufferList
                guard list.pointee.mNumberBuffers == 1 else {
                    throw "Not sure what to do with this"
                }

                // Get audio data as packet list.
                let audioBuffer = list.pointee.mBuffers
                guard let data = audioBuffer.mData else {
                    throw "AudioBuffer data was nil"
                }
                assert(packet.pointee.length == audioBuffer.mDataByteSize)
                memcpy(packet.pointee.data, data, packet.pointee.length)
                concealed += UInt64(packet.pointee.elements)
            } catch {
                OpusHandler.logger.error("\(error.localizedDescription)")
            }
        }
        if let measurement = handler.measurement {
            let constConcealed = concealed
            let timestamp: Date? = handler.granularMetrics ? .now : nil
            Task(priority: .utility) {
                measurement.measurement.concealmentFrames(concealed: constConcealed,
                                                          timestamp: timestamp)
            }
        }
    }

    private func queueDecodedAudio(buffer: AVAudioPCMBuffer, timestamp: Date?, sequence: UInt64) throws {
        // Ensure this buffer looks valid.
        let list = buffer.audioBufferList
        guard list.pointee.mNumberBuffers == 1 else {
            throw "Unexpected number of buffers"
        }

        // Get audio data as packet list.
        let audioBuffer = list.pointee.mBuffers
        guard let data = audioBuffer.mData else {
            Self.logger.error("AudioBuffer data was nil")
            return
        }

        let packet: Packet = .init(sequence_number: UInt(sequence),
                                   data: data,
                                   length: Int(audioBuffer.mDataByteSize),
                                   elements: Int(buffer.frameLength))

        let selfPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let jitterBuffer = self.oldJitterBuffer else {
            fatalError()
        }
        // Copy in.
        let copied = jitterBuffer.enqueue(packet,
                                          concealmentCallback: self.plcCallback,
                                          userData: selfPtr)

        let missing = copied < buffer.frameLength ? Int(buffer.frameLength) - copied : 0
        if let measurement = measurement {
            Task(priority: .utility) {
                await measurement.measurement.receivedFrames(received: buffer.frameLength,
                                                             timestamp: timestamp)
                await measurement.measurement.recordLibJitterMetrics(metrics: jitterBuffer.getMetrics(),
                                                                     timestamp: timestamp)
                await measurement.measurement.droppedFrames(dropped: missing,
                                                            timestamp: timestamp)
            }
        }
    }

    private func createDequeueTask() {
        // Start the frame dequeue task.
        self.dequeueTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                let waitTime: TimeInterval
                let now: Date
                let windowSize: OpusWindowSize
                if let self = self {
                    now = Date.now
                    // Get current window size / backup wait.
                    if let set = self.windowSize {
                        windowSize = set
                    } else {
                        let stored = self.windowSizeUs.load(ordering: .acquiring)
                        if stored == 0 {
                            windowSize = .twentyMs
                        } else {
                            let interval = TimeInterval(stored) / microsecondsPerSecond
                            guard let window = OpusWindowSize(rawValue: interval) else {
                                Self.logger.error("Bad opus window size calculation")
                                return
                            }
                            self.windowSize = window
                            windowSize = window
                        }
                    }

                    // Wait until we expect to have a frame available.
                    let calc = self.calculateWaitTime(from: now)
                    waitTime = calc ?? windowSize.rawValue
                } else {
                    return
                }

                // Sleep without holding a strong reference.
                if waitTime > 0 {
                    try? await Task.sleep(for: .seconds(waitTime),
                                          tolerance: .seconds(waitTime / 2),
                                          clock: .continuous)
                }

                // Regain our strong reference after sleeping.
                if let self = self {
                    // Attempt to dequeue an opus packet.
                    guard let item: AudioJitterItem  = self.jitterBuffer!.read(from: now) else { continue }

                    // Record the actual delay (difference between when this should
                    // be presented, and now).
                    if self.granularMetrics,
                       let measurement = self.measurement?.measurement {
                        let now = Date.now
                        if let time = self.calculateWaitTime(item: item, from: now) {
                            Task(priority: .utility) {
                                await measurement.frameDelay(delay: time, metricsTimestamp: now)
                            }
                        }
                    }

                    // Decode, conceal, enqueue for playout.
                    self.decodeWithConcealment(item, window: windowSize, when: now)
                }
            }
        }
    }

    private func decodeWithConcealment(_ item: AudioJitterItem, window: OpusWindowSize, when: Date) {
        // Deal with any discontinuity.
        if var lastUsedSequence = self.lastUsedSequence,
           item.sequenceNumber > lastUsedSequence,
           item.sequenceNumber != lastUsedSequence + 1 {
            // There is a discontinuity.
            let packetsToGenerate = item.sequenceNumber - lastUsedSequence - 1
            Self.logger.warning("Need to conceal \(packetsToGenerate) packets.")
            for _ in 0..<packetsToGenerate {
                do {
                    let frames = AVAudioFrameCount(window.rawValue * 48000) // TODO: Sample rate??
                    let plc = try self.decoder.plc(frames: frames)
                    lastUsedSequence += 1
                    self.jitterBuffer!.updateLastSequenceRead(lastUsedSequence)
                    var timestamp = AudioTimeStamp()
                    do {
                        try self.playoutBuffer?.enqueue(buffer: &plc.mutableAudioBufferList.pointee,
                                                        timestamp: &timestamp,
                                                        frames: nil)
                    } catch {
                        Self.logger.warning("Couldn't enqueue PLC data: \(error.localizedDescription)")
                        if let measurement = self.measurement?.measurement {
                            Task(priority: .utility) {
                                await measurement.playoutFull(timestamp: self.granularMetrics ? when : nil)
                            }
                        }
                    }
                } catch {
                    Self.logger.error("Failure generating PLC: \(error.localizedDescription)")
                }
            }
        }
        self.lastUsedSequence = item.sequenceNumber

        // Set window size.
        if self.windowSizeUs.load(ordering: .acquiring) == 0 {
            do {
                let frames = try self.decoder.frames(data: item.data)
                let windowSize: TimeInterval = TimeInterval(frames) / 48000 // TODO: sample rate comes from??
                self.windowSizeUs.store(.init(windowSize * microsecondsPerSecond), ordering: .releasing)
            } catch {
                Self.logger.error("Failed to extract frame count from Opus")
            }
        }

        // Decode.
        guard let decoded = try? self.decoder.write(data: item.data) else {
            Self.logger.error("Failed to decode audio")
            return
        }

        // Enqueue for playout.
        var timestamp = AudioTimeStamp()
        do {
            guard let playoutBuffer = self.playoutBuffer else {
                Self.logger.error("Missing playout buffer")
                return
            }
            let depth = playoutBuffer.peek().frames
            if self.granularMetrics,
               let measurement = self.measurement?.measurement {
                Task(priority: .utility) {
                    let depthMs = TimeInterval(depth) / 48000 * 1000
                    await measurement.depth(depthMs: Int(depthMs), timestamp: when)
                }
            }
            try playoutBuffer.enqueue(buffer: &decoded.mutableAudioBufferList.pointee,
                                      timestamp: &timestamp,
                                      frames: nil)
        } catch {
            Self.logger.warning("Failed to enqueue decoded audio to playout buffer: \(error.localizedDescription)")
            if let measurement = self.measurement?.measurement {
                Task(priority: .utility) {
                    await measurement.playoutFull(timestamp: self.granularMetrics ? when : nil)
                }
            }
        }
    }
}

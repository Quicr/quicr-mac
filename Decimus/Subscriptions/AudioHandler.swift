// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Accelerate
import Foundation
import AVFAudio
import CoreAudio
import Synchronization

enum OpusSubscriptionError: Error {
    case failedDecoderCreation
}

protocol AudioDecoder {
    var decodedFormat: AVAudioFormat { get }
    var encodedFormat: AVAudioFormat { get }
    func write(data: Data) throws -> AVAudioPCMBuffer
    func frames(data: Data) throws -> AVAudioFrameCount
    func plc(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer
    func reset() throws
}

class AudioHandler: TimeAlignable {
    struct Config {
        let jitterDepth: TimeInterval
        let jitterMax: TimeInterval
        let opusWindowSize: OpusWindowSize
        let granularMetrics: Bool
        let useNewJitterBuffer: Bool
        let maxPlcThreshold: Int
        let playoutBufferTime: TimeInterval
        let slidingWindowTime: TimeInterval
        let adaptive: Bool
    }

    private static let logger = DecimusLogger(AudioHandler.self)
    private let identifier: String
    private var decoder: AudioDecoder
    private let engine: DecimusAudioEngine
    private let asbd: UnsafeMutablePointer<AudioStreamBasicDescription>
    private var node: AVAudioSourceNode?
    private var oldJitterBuffer: QJitterBuffer?
    private var playoutBuffer: CircularBuffer?
    private let measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?
    private let underrun = Atomic<UInt64>(0)
    private let callbacks = Atomic<UInt64>(0)
    private let silenceRemoved = Atomic<UInt64>(0)
    private let granularMetrics: Bool
    private var dequeueTask: Task<Void, Never>?
    private var lastUsedSequence: UInt64?
    private let windowSizeUs = Atomic<UInt32>(0)
    private var windowSize: OpusWindowSize?
    private let metricsSubmitter: MetricsSubmitter?
    private let config: Config
    private let playing: Atomic<Bool> = .init(false)
    private let jitterCalculation: RFC3550Jitter

    private var silenceDetectionBuffer: UnsafeMutableBufferPointer<Float32>?

    // Time based buffer.
    private var timeAligner: TimeAligner?

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
         decoder: AudioDecoder,
         measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?,
         metricsSubmitter: MetricsSubmitter?,
         config: Config) throws {
        self.identifier = identifier
        self.engine = engine
        self.measurement = measurement
        self.granularMetrics = config.granularMetrics
        self.decoder = decoder
        self.asbd = .init(mutating: decoder.decodedFormat.streamDescription)
        self.config = config
        self.metricsSubmitter = metricsSubmitter
        self.jitterCalculation = .init(identifier: identifier, submitter: metricsSubmitter)
        super.init()
        if !self.config.useNewJitterBuffer {
            // Create the jitter buffer.
            let opusPacketSize = self.asbd.pointee.mSampleRate * config.opusWindowSize.rawValue
            self.oldJitterBuffer = QJitterBuffer(elementSize: Int(asbd.pointee.mBytesPerPacket),
                                                 packetElements: Int(opusPacketSize),
                                                 clockRate: UInt(asbd.pointee.mSampleRate),
                                                 maxLengthMs: UInt(config.jitterMax * 1000),
                                                 minLengthMs: UInt(config.jitterDepth * 1000)) { level, msg, alert in
                AudioHandler.logger.log(level: DecimusLogger.LogLevel(rawValue: level)!, msg!, alert: alert)
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
            Self.logger.warning("Couldn't remove player: \(error.localizedDescription)")
        }

        // Reset the node.
        node?.reset()

        // Deallocate silence detection buffer.
        if let silenceDetectionBuffer = self.silenceDetectionBuffer {
            silenceDetectionBuffer.deallocate()
            self.silenceDetectionBuffer = nil
        }
    }

    func createNewJitterBuffer(windowDuration: CMTime) throws -> JitterBuffer {
        guard self.config.useNewJitterBuffer else { throw "Configuration Issue" }
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
        guard windowDuration.seconds > 0 else { throw "Bad window size" }
        let buffer = try JitterBuffer(identifier: self.identifier,
                                      metricsSubmitter: self.metricsSubmitter,
                                      minDepth: self.config.jitterDepth,
                                      capacity: Int(self.config.jitterMax / windowDuration.seconds),
                                      handlers: handlers)
        self.jitterBuffer = buffer

        let format = DecimusAudioEngine.format
        let playoutLength = UInt32(format.sampleRate *
                                    Double(format.streamDescription.pointee.mBytesPerFrame) *
                                    self.config.jitterMax)
        self.playoutBuffer = try .init(length: playoutLength,
                                       format: self.asbd.pointee)
        let slidingWindowLength: TimeInterval = self.config.slidingWindowTime
        let capacity = Int(slidingWindowLength * (1.0 / self.config.opusWindowSize.rawValue))
        self.timeAligner = .init(windowLength: slidingWindowLength,
                                 capacity: capacity) { [weak self] in
            guard let self = self else { return [] }
            return [self]
        }
        self.createDequeueTask()
        // Create the player node.
        let node = AVAudioSourceNode(format: self.decoder.decodedFormat, renderBlock: self.renderBlock)
        self.node = node
        try self.engine.addPlayer(identifier: self.identifier, node: node)
        return buffer
    }

    func submitEncodedAudio(data: Data, sequence: UInt64, date: Ticks, timestamp: Date) throws {
        if self.config.useNewJitterBuffer {
            let jitterBuffer: JitterBuffer
            if let existing = self.jitterBuffer {
                jitterBuffer = existing
            } else {
                // What's the duration of this packet?
                let frames = try self.decoder.frames(data: data)
                let duration = TimeInterval(frames) / self.decoder.encodedFormat.sampleRate
                let durationUs = duration * microsecondsPerSecond
                let cmDuration = CMTime(value: CMTimeValue(durationUs), timescale: CMTimeScale(microsecondsPerSecond))
                // Create jitter buffer.
                jitterBuffer = try self.createNewJitterBuffer(windowDuration: cmDuration)
            }

            // Set the timestamp diff from the first recveived object.
            self.timeAligner!.doTimestampTimeDiff(timestamp.timeIntervalSince1970, when: date)

            // Jitter calculation.
            if self.config.adaptive {
                self.jitterCalculation.record(timestamp: timestamp.timeIntervalSince1970, arrival: date.hostDate)
                let newTarget = max(self.config.jitterDepth - self.config.playoutBufferTime,
                                    (self.jitterCalculation.smoothed * 3) - self.config.playoutBufferTime)
                if let jitterBuffer = self.jitterBuffer {
                    let existing = jitterBuffer.getBaseTargetDepth()
                    let change = (newTarget - existing) / existing
                    if change > 0 || change < -0.1 {
                        jitterBuffer.setBaseTargetDepth(newTarget)
                    }
                }
            }

            // TODO: Is this right?
            // We don't want to emplace this if we're not playing out yet.
            guard self.playing.load(ordering: .acquiring) else { return }

            // Emplace this encoded data into the jitter buffer.
            let usSinceEpoch = timestamp.timeIntervalSince1970 * microsecondsPerSecond
            let timestamp = CMTime(value: CMTimeValue(usSinceEpoch), timescale: CMTimeScale(microsecondsPerSecond))
            let item = AudioJitterItem(data: data, sequenceNumber: sequence, timestamp: timestamp)
            do {
                try jitterBuffer.write(item: item, from: date.hostDate)
            } catch JitterBufferError.full {
                Self.logger.warning("Didn't enqueue audio as jitter buffer is full")
            } catch JitterBufferError.old {
                Self.logger.warning("Didn't enqueue audio as already concealed / used")
            }

            if let measurement = self.measurement {
                let metricsDate = self.granularMetrics ? date.hostDate : nil
                Task(priority: .utility) {
                    await measurement.measurement.callbacks(callbacks: self.callbacks.load(ordering: .relaxed),
                                                            timestamp: metricsDate)
                    await measurement.measurement.removedSilence(removed: self.silenceRemoved.load(ordering: .relaxed),
                                                                 timestamp: metricsDate)
                    await measurement.measurement.framesUnderrun(underrun: self.underrun.load(ordering: .relaxed),
                                                                 timestamp: metricsDate)
                }
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
        try self.queueDecodedAudio(buffer: decoded, timestamp: date.hostDate, sequence: sequence)

        // Metrics.
        let metricsDate = self.granularMetrics ? date.hostDate : nil
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

    private lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [weak self] silence, timestamp, numFrames, data in
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
            Self.logger.error("""
                              Unexpected render block channels. \
                              Got \(data.pointee.mBuffers.mNumberChannels). \
                              Expected \(self.asbd.pointee.mChannelsPerFrame)
                              """)
            return 1
        }

        let buffer: AudioBuffer = data.pointee.mBuffers
        assert(buffer.mDataByteSize == numFrames * self.asbd.pointee.mBytesPerFrame)

        var copiedFrames = 0
        if let playoutBuffer = self.playoutBuffer {
            // Dequeue audio from the playout buffer, catching up where late if possible.
            var currentDestination = data.pointee
            var currentDestinationSamples = numFrames
            assert(numFrames == currentDestination.mBuffers.mDataByteSize / self.asbd.pointee.mBytesPerFrame)
            var iterations = 0
            while currentDestinationSamples > 0 {
                iterations += 1
                let currentSamples = Int(currentDestinationSamples)
                if self.silenceDetectionBuffer == nil {
                    self.silenceDetectionBuffer = .allocate(capacity: currentSamples)
                } else if let buffer = self.silenceDetectionBuffer,
                          buffer.count < currentSamples {
                    buffer.deallocate()
                    self.silenceDetectionBuffer = .allocate(capacity: currentSamples)
                }

                // Work in timed chunks.
                let analysisSizeTime: TimeInterval = 0.005 // 5ms.
                let analysisSizeFrames = AVAudioFrameCount(ceil(analysisSizeTime * self.asbd.pointee.mSampleRate))

                // Attempt to dequeue the required frames from the playout buffer.
                let result = playoutBuffer.dequeue(frames: currentDestinationSamples, buffer: &currentDestination)
                guard result.frames > 0 else {
                    // No frames were available, so we're done.
                    break
                }
                var validThisPass = result.frames

                // How early or late is this frame?
                let now = timestamp.pointee.mHostTime
                let dueAt = result.timestamp.mHostTime
                let dueIn = SignedTicks(dueAt) - SignedTicks(now)
                let lateThreshold = SignedTicks(self.config.playoutBufferTime.ticks)
                // TODO: This doubling is a bit of a hack.
                guard dueIn < (-lateThreshold * 2) else {
                    // This wasn't late, we're done.
                    copiedFrames += Int(validThisPass)
                    break
                }

                // Late!
                // If there is more data to consume, we should remove any silence, and dequeue more to fill.
                let remaining = playoutBuffer.peek().frames
                guard remaining > 0 else {
                    // Nothing left to use, nothing we can do.
                    copiedFrames += Int(validThisPass)
                    break
                }

                // There are more frames to consume, so let's try and catch up a bit by removing silence.

                var writeIndex = 0
                let silenceThreshold: Float32 = 0.001
                var removed: AVAudioFrameCount = 0

                assert(self.asbd.pointee.mBytesPerFrame == MemoryLayout<Float32>.size)
                let lengthSamples: UnsafeMutableBufferPointer<Float32>
                lengthSamples = .init(start: currentDestination.mBuffers.mData?.bindMemory(to: Float32.self,
                                                                                           capacity: currentSamples),
                                      count: currentSamples)

                // Silence detection.
                let dequeuedFrames = result.frames
                vDSP_vabs(lengthSamples.baseAddress!,
                          1,
                          self.silenceDetectionBuffer!.baseAddress!,
                          1,
                          vDSP_Length(lengthSamples.count))

                var index = 0
                let incrementBy = min(Int(analysisSizeFrames), lengthSamples.count)
                while index <= lengthSamples.count - incrementBy {
                    let rms = Self.rms(buffer: self.silenceDetectionBuffer!.baseAddress!.advanced(by: index),
                                       count: incrementBy)
                    if rms < silenceThreshold {
                        // Skip this entire silent chunk.
                        removed += AVAudioFrameCount(incrementBy)
                        validThisPass -= AVAudioFrameCount(incrementBy)
                        guard removed < remaining else { break }
                    } else {
                        // Keep this chunk.
                        if index != writeIndex {
                            memmove(lengthSamples.baseAddress!.advanced(by: writeIndex),
                                    lengthSamples.baseAddress!.advanced(by: index),
                                    Int(incrementBy) * MemoryLayout<Float32>.size)
                        }
                        writeIndex += incrementBy
                    }
                    index += incrementBy
                }

                // Remainder.
                let leftToCheck = lengthSamples.count - index
                if leftToCheck > 0 && remaining > removed + AVAudioFrameCount(leftToCheck) {
                    let rms = Self.rms(buffer: self.silenceDetectionBuffer!.baseAddress!.advanced(by: index),
                                       count: leftToCheck)
                    if rms < silenceThreshold {
                        // Skip this entire silent chunk.
                        removed += AVAudioFrameCount(leftToCheck)
                        validThisPass -= AVAudioFrameCount(leftToCheck)
                    } else {
                        // Keep this chunk.
                        if index != writeIndex {
                            memmove(lengthSamples.baseAddress!.advanced(by: writeIndex),
                                    lengthSamples.baseAddress!.advanced(by: index),
                                    leftToCheck * MemoryLayout<Float32>.size)
                        }
                        writeIndex += leftToCheck
                    }
                    index += incrementBy
                }

                if removed > 0 {
                    self.silenceRemoved.wrappingAdd(UInt64(removed), ordering: .relaxed)
                }

                // Now we attempt to dequeue more frames to fill up to the target.
                // Update our state, and iterate.

                // Bytes we just filled.
                let usedBytes = validThisPass * self.asbd.pointee.mBytesPerFrame
                // Move the buffer forward.
                currentDestination.mBuffers.mData = currentDestination.mBuffers.mData!.advanced(by: Int(usedBytes))
                // Update available space.
                currentDestination.mBuffers.mDataByteSize -= UInt32(usedBytes)
                // Update required samples.
                currentDestinationSamples -= validThisPass
                // Update total frames copied this pass.
                copiedFrames += Int(validThisPass)

                #if DEBUG
                let timeSaved = TimeInterval(removed) * (1.0 / self.asbd.pointee.mSampleRate) * 1000
                // swiftlint:disable:next line_length
                Self.logger.debug("Audio was late at playout: \(Ticks(abs(dueIn)).seconds * 1000)ms. Removed \(removed) (\(timeSaved)ms) silent frames. Took: \(iterations) iterations")
                #endif
            }
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

    private static func rms(buffer: UnsafeMutablePointer<Float32>, count: Int) -> Float32 {
        var sum: Float32 = 0.0
        let count = vDSP_Length(count)
        vDSP_svesq(buffer, 1, &sum, count)
        return sqrt(sum / Float32(count))
    }

    private let plcCallback: PacketCallback = { packets, count, userData in
        guard let userData = userData else {
            AudioHandler.logger.error("Expected self in userData")
            return
        }
        let handler: AudioHandler = Unmanaged<AudioHandler>.fromOpaque(userData).takeUnretainedValue()
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
                AudioHandler.logger.error("\(error.localizedDescription)")
            }
        }
        if let measurement = handler.measurement {
            let constConcealed = concealed
            let timestamp: Date? = handler.granularMetrics ? .now : nil
            Task(priority: .utility) {
                await measurement.measurement.concealmentFrames(concealed: constConcealed,
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
                let windowSize: OpusWindowSize
                if let self = self {
                    let now = Ticks.now
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
                    if let calc = self.calculateWaitTime(from: now) {
                        // Deliberately dequeue early to account for the playout buffer target size.
                        waitTime = calc - self.config.playoutBufferTime
                    } else {
                        waitTime = windowSize.rawValue
                    }
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
                    let now = Ticks.now
                    guard let item: AudioJitterItem  = self.jitterBuffer!.read(from: now.hostDate) else { continue }

                    // Record the actual delay (difference between when this should
                    // be presented, and now).
                    if self.granularMetrics,
                       let measurement = self.measurement?.measurement {
                        if let time = self.calculateWaitTime(item: item, from: now) {
                            Task(priority: .utility) {
                                // Adjust this time to reflect our deliberate early dequeue.
                                let time = time - self.config.playoutBufferTime
                                await measurement.frameDelay(delay: -time, metricsTimestamp: now.hostDate)
                            }
                        }
                    }

                    // Decode, conceal, enqueue for playout.
                    self.checkForDiscontinuity(item, window: windowSize, when: now.hostDate)
                    self.decode(item, when: now.hostDate)
                }
            }
        }
    }

    private func decode(_ item: AudioJitterItem, when: Date) {
        self.lastUsedSequence = item.sequenceNumber

        // Set window size.
        if self.windowSizeUs.load(ordering: .acquiring) == 0 {
            do {
                let frames = try self.decoder.frames(data: item.data)
                let windowSize: TimeInterval = TimeInterval(frames) / self.decoder.encodedFormat.sampleRate
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
        guard let diff = self.timeDiff.getTimeDiff() else {
            Self.logger.error("Missing timing info, cannot use this audio")
            return
        }
        let playout = self.jitterBuffer!.getPlayoutDate(item: item, offset: diff)
        var timestamp = AudioTimeStamp(mSampleTime: 0,
                                       mHostTime: playout,
                                       mRateScalar: 0,
                                       mWordClockTime: 0,
                                       mSMPTETime: .init(),
                                       mFlags: .hostTimeValid,
                                       mReserved: 0)
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

    private func checkForDiscontinuity(_ item: AudioJitterItem, window: OpusWindowSize, when: Date) {
        // Check for discontinuity.
        guard var lastUsedSequence,
              item.sequenceNumber > lastUsedSequence,
              item.sequenceNumber != lastUsedSequence + 1 else {
            return
        }

        // Are we within the generation threshold?
        let packetsToGenerate = item.sequenceNumber - lastUsedSequence - 1
        guard packetsToGenerate <= self.config.maxPlcThreshold else {
            Self.logger.warning("Discontinuity too large: \(packetsToGenerate)")
            self.playoutBuffer?.clear()
            do {
                try self.decoder.reset()
            } catch {
                Self.logger.warning("Couldn't reset decoder: \(error.localizedDescription)")
            }
            do {
                try self.jitterBuffer?.clear()
            } catch {
                Self.logger.warning("Couldn't clear jitter buffer: \(error.localizedDescription)")
            }
            return
        }

        // Generate PLC.
        // TODO: If this won't fit in the playout buffer, don't generate it.
        Self.logger.warning("Need to conceal \(packetsToGenerate) packets.")
        // Enqueue for playout.
        guard let diff = self.timeDiff.getTimeDiff() else {
            Self.logger.error("Missing timing info, cannot use this audio")
            return
        }
        let itemDate = self.jitterBuffer!.getPlayoutDate(item: item, offset: diff)
        for packet in 0..<packetsToGenerate {
            do {
                let frames = AVAudioFrameCount(window.rawValue * self.decoder.encodedFormat.sampleRate)
                let plc = try self.decoder.plc(frames: frames)
                lastUsedSequence += 1
                self.jitterBuffer!.updateLastSequenceRead(lastUsedSequence)
                let backwards = packetsToGenerate - packet
                let backwardsTicks = (TimeInterval(backwards) * window.rawValue).ticks
                let date = itemDate - backwardsTicks
                var timestamp = AudioTimeStamp(mSampleTime: 0,
                                               mHostTime: date,
                                               mRateScalar: 0,
                                               mWordClockTime: 0,
                                               mSMPTETime: .init(),
                                               mFlags: .hostTimeValid,
                                               mReserved: 0)
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
}

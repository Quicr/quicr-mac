// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import CoreAudio
import Atomics
import CTPCircularBuffer

enum OpusSubscriptionError: Error {
    case failedDecoderCreation
}

private class Weak<T> {
    var value: T
    init(value: T) {
        self.value = value
    }
}

class OpusHandler {
    private static let logger = DecimusLogger(OpusHandler.self)
    private let sourceId: SourceIDType
    private var decoder: LibOpusDecoder
    private let engine: DecimusAudioEngine
    private let asbd: UnsafeMutablePointer<AudioStreamBasicDescription>
    private var node: AVAudioSourceNode?
    private var jitterBuffer: QJitterBuffer?
    private var newJitterBuffer: JitterBuffer?
    private var playoutBuffer: CircularBuffer?
    private let measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?
    private var underrun = ManagedAtomic<UInt64>(0)
    private var callbacks = ManagedAtomic<UInt64>(0)
    private let granularMetrics: Bool
    private var dequeueTask: Task<Void, Never>?
    private var timestampTimeDiffUs = ManagedAtomic(Int64.zero)
    private var lastUsedSequence: UInt64?
    
    class AudioJitterItem: JitterBuffer.JitterItem {
        let data: Data
        let sequenceNumber: UInt64
        let timestamp: CMTime
        
        init(data: Data, sequenceNumber: UInt64, timestamp: CMTime) {
            self.data = data
            self.sequenceNumber = sequenceNumber
            self.timestamp = timestamp
        }
    }

    init(sourceId: SourceIDType,
         engine: DecimusAudioEngine,
         measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         granularMetrics: Bool,
         useNewJitterBuffer: Bool) throws {
        self.sourceId = sourceId
        self.engine = engine
        self.measurement = measurement
        self.granularMetrics = granularMetrics
        self.decoder = try .init(format: DecimusAudioEngine.format)
        self.asbd = .init(mutating: decoder.decodedFormat.streamDescription)
        if useNewJitterBuffer {
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
                    .invalid
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
            self.newJitterBuffer = try .init(fullTrackName: .init(namespace: sourceId, name: ""),
                                             metricsSubmitter: nil,
                                             minDepth: jitterDepth,
                                             capacity: 1000,
                                             handlers: handlers)
            self.playoutBuffer = try .init(length: 1, format: self.asbd.pointee)
            self.jitterBuffer = nil
            self.createDequeueTask()
        } else {
            // Create the jitter buffer.
            let opusPacketSize = self.asbd.pointee.mSampleRate * opusWindowSize.rawValue
            self.jitterBuffer = QJitterBuffer(elementSize: Int(asbd.pointee.mBytesPerPacket),
                                              packetElements: Int(opusPacketSize),
                                              clockRate: UInt(asbd.pointee.mSampleRate),
                                              maxLengthMs: UInt(jitterMax * 1000),
                                              minLengthMs: UInt(jitterDepth * 1000)) { level, msg, alert in
                OpusHandler.logger.log(level: DecimusLogger.LogLevel(rawValue: level)!, msg!, alert: alert)
            }
            self.newJitterBuffer = nil
        }

        // Create the player node.
        self.node = .init(format: decoder.decodedFormat, renderBlock: renderBlock)
        try self.engine.addPlayer(identifier: sourceId, node: node!)
    }

    deinit {
        // Remove the audio playout.
        do {
            try engine.removePlayer(identifier: sourceId)
        } catch {
            Self.logger.error("Couldn't remove player: \(error.localizedDescription)")
        }

        // Reset the node.
        node?.reset()
    }

    func submitEncodedAudio(data: Data, sequence: UInt64, date: Date) throws {
        if let jitterBuffer = self.newJitterBuffer {
            // All we need to do is emplace this into the jitter buffer.
            let timestamp: CMTime = .invalid
            let item = AudioJitterItem(data: data, sequenceNumber: sequence, timestamp: timestamp)
            try jitterBuffer.write(item: item, from: date)
        } else {
            // Generate PLC prior to real decode.
            guard let jitterBuffer = self.jitterBuffer else {
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
    }

    private lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [jitterBuffer, playoutBuffer, asbd, weak underrun, weak callbacks] silence, _, numFrames, data in
        // Fill the buffers as best we can.
        if let callbacks = callbacks {
            callbacks.wrappingIncrement(by: UInt64(numFrames), ordering: .relaxed)
        }
        guard data.pointee.mNumberBuffers == 1 else {
            // Unexpected.
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            Self.logger.error("Got multiple buffers: \(data.pointee.mNumberBuffers)")
            for (idx, buffer) in buffers.enumerated() {
                Self.logger.error("Buffer \(idx) size: \(buffer.mDataByteSize), channels: \(buffer.mNumberChannels)")
            }
            return 1
        }

        guard data.pointee.mBuffers.mNumberChannels == asbd.pointee.mChannelsPerFrame else {
            Self.logger.error("Unexpected render block channels. Got \(data.pointee.mBuffers.mNumberChannels). Expected \(asbd.pointee.mChannelsPerFrame)")
            return 1
        }

        let buffer: AudioBuffer = data.pointee.mBuffers
        assert(buffer.mDataByteSize == numFrames * asbd.pointee.mBytesPerFrame)
        
        
        let copiedFrames: Int
        if let playoutBuffer = playoutBuffer {
            let result = playoutBuffer.dequeue(frames: numFrames, buffer: &data.pointee)
            copiedFrames = Int(result.frames)
        } else {
            guard let jitterBuffer = jitterBuffer else {
                fatalError()
            }
            copiedFrames = jitterBuffer.dequeue(buffer.mData,
                                                destinationLength: Int(buffer.mDataByteSize),
                                                elements: Int(numFrames))
        }
        guard copiedFrames == numFrames else {
            // Ensure any incomplete data is pure silence.
            let framesUnderan = UInt64(numFrames) - UInt64(copiedFrames)
            silence.pointee = .init(framesUnderan == numFrames)
            if let underrun = underrun {
                underrun.wrappingIncrement(by: framesUnderan, ordering: .relaxed)
            }
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            for buffer in buffers {
                guard let dataPointer = buffer.mData else {
                    break
                }
                let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
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
        guard let jitterBuffer = self.jitterBuffer else {
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
                if let self = self {
                    now = Date.now
                    // Wait until we expect to have a frame available.
                    waitTime = self.calculateWaitTime(from: now) ?? (20 / 1000)
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
                    if let item: AudioJitterItem = self.newJitterBuffer!.read(from: now) {
                        if self.granularMetrics,
                           let measurement = self.measurement?.measurement,
                           let time = self.calculateWaitTime(packet: item) {
                            Task(priority: .utility) {
                                // await measurement.frameDelay(delay: time, metricsTimestamp: now)
                            }
                        }
                        // We got an opus packet. Do we have any discontinuity?
                        self.decodeWithConcealment(item)
                    }
                }
            }
        }
    }
    
    private func decodeWithConcealment(_ item: AudioJitterItem) {
        // Deal with any discontinuity.
        if var lastUsedSequence = self.lastUsedSequence,
           item.sequenceNumber != lastUsedSequence + 1 {
            // There is a discontinuity.
            let packetsToGenerate = item.sequenceNumber - lastUsedSequence - 1
            for _ in 0..<packetsToGenerate {
                do {
                    // TODO: Calculate frames.
                    // TODO: Move jitter buffer last read along by this.
                    let plc = try self.decoder.plc(frames: 480)
                    lastUsedSequence += 1
                    self.newJitterBuffer!.updateLastSequenceRead(lastUsedSequence)
                    var timestamp = AudioTimeStamp()
                    try self.playoutBuffer?.enqueue(buffer: &plc.mutableAudioBufferList.pointee,
                                                    timestamp: &timestamp,
                                                    frames: nil)
                } catch {
                    Self.logger.warning("Failure generating PLC: \(error.localizedDescription)")
                }
            }
            self.lastUsedSequence = lastUsedSequence
        }
        
        // Decode and enqueue the real data.
        do {
            let decoded = try self.decoder.write(data: item.data)
            var timestamp = AudioTimeStamp()
            try self.playoutBuffer?.enqueue(buffer: &decoded.mutableAudioBufferList.pointee,
                                            timestamp: &timestamp,
                                            frames: nil)
        } catch {
            Self.logger.error("Failed to decode real audio")
        }
        
    }
    
    /// Calculates the time until the next packet would be expected, or nil if there is no next packet.
    /// - Parameter from: The time to calculate from.
    /// - Returns Time to wait in seconds, if any.
    func calculateWaitTime(from: Date) -> TimeInterval? {
        guard let jitterBuffer = self.newJitterBuffer else { return nil }
        let diffUs = self.timestampTimeDiffUs.load(ordering: .acquiring)
        guard diffUs > 0 else { return nil }
        let diff = TimeInterval(diffUs) / 1_000_000.0
        return jitterBuffer.calculateWaitTime(from: from, offset: diff)
    }

    private func calculateWaitTime(packet: AudioJitterItem, from: Date = .now) -> TimeInterval? {
        guard let jitterBuffer = self.newJitterBuffer else {
            assert(false)
            Self.logger.error("App misconfiguration, please report this")
            return nil
        }
        let diffUs = self.timestampTimeDiffUs.load(ordering: .acquiring)
        guard diffUs > 0 else {
            assert(false)
            Self.logger.warning("Missing initial timestamp")
            return nil
        }
        let diff = TimeInterval(diffUs) / 1_000_000.0
        return jitterBuffer.calculateWaitTime(item: packet, from: from, offset: diff)
    }

    /// Set the difference in time between incoming stream timestamps and wall clock.
    /// - Parameter diff: Difference in time in seconds.
    func setTimeDiff(diff: TimeInterval) {
        let diffUs = min(Int64(diff * 1_000_000), 1)
        _ = self.timestampTimeDiffUs.compareExchange(expected: 0,
                                                     desired: diffUs,
                                                     ordering: .acquiringAndReleasing)
    }
}

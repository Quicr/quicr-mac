// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFAudio
import CoreMedia
import Synchronization
import Testing
@testable import QuicR

struct AudioHandlerTests {
    private func makeFormat() throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000,
                                   channels: 1,
                                   interleaved: false))
    }

    private func makeEndpoints(format: AVAudioFormat) throws -> CircularBuffer.Endpoints {
        try CircularBuffer.makeSPSC(length: 16_384,
                                    format: format.streamDescription.pointee)
    }

    private func makeBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        return buffer
    }

    private func makeTimestamp() -> AudioTimeStamp {
        var timestamp = AudioTimeStamp()
        timestamp.mHostTime = 42
        timestamp.mFlags = .hostTimeValid
        return timestamp
    }

    @Test("Pointer copy realloc")
    func testAudioHandler() {
        var buffer: UnsafeMutableBufferPointer<Float32>?
        buffer = UnsafeMutableBufferPointer<Float32>.allocate(capacity: 10)
        if let unwrapped = buffer {
            unwrapped.deallocate()
            buffer = .allocate(capacity: 20)
        }
        buffer?.deallocate()
    }

    @Test("Playout endpoints track depth across enqueue and dequeue")
    func playoutDepth() throws {
        let format = try self.makeFormat()
        let endpoints = try self.makeEndpoints(format: format)
        let input = try self.makeBuffer(format: format)
        let output = try self.makeBuffer(format: format)
        var timestamp = self.makeTimestamp()

        try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                     timestamp: &timestamp,
                                     frames: nil)
        #expect(endpoints.writer.depthFrames == 960)

        let result = endpoints.reader.dequeue(frames: 480,
                                              buffer: &output.mutableAudioBufferList.pointee)
        #expect(result.frames == 480)
        #expect(result.timestamp.mHostTime == 42)
        #expect(endpoints.writer.depthFrames == 480)
    }

    @Test("Playout clear is performed and acknowledged by the reader")
    func playoutClearAcknowledgement() throws {
        let format = try self.makeFormat()
        let endpoints = try self.makeEndpoints(format: format)
        let input = try self.makeBuffer(format: format)
        var timestamp = self.makeTimestamp()
        try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                     timestamp: &timestamp,
                                     frames: nil)

        // Repeated requests coalesce, and the data survives until the reader acts.
        _ = endpoints.writer.requestClear()
        _ = endpoints.writer.requestClear()
        #expect(endpoints.reader.peek().frames == 960)

        #expect(endpoints.reader.processClearRequest())
        #expect(endpoints.writer.depthFrames == 0)
        #expect(endpoints.reader.peek().frames == 0)
        #expect(!endpoints.reader.processClearRequest())

        // A subsequent clear is a fresh request, not a no-op.
        try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                     timestamp: &timestamp,
                                     frames: nil)
        _ = endpoints.writer.requestClear()
        #expect(endpoints.reader.processClearRequest())
        #expect(endpoints.writer.depthFrames == 0)
    }

    @Test("Playout writer rejects audio until a requested clear is acknowledged")
    func playoutClearBlocksWriter() throws {
        let format = try self.makeFormat()
        let endpoints = try self.makeEndpoints(format: format)
        let input = try self.makeBuffer(format: format)
        var timestamp = self.makeTimestamp()
        _ = endpoints.writer.requestClear()

        #expect(throws: CircularBufferError.clearPending) {
            try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                         timestamp: &timestamp,
                                         frames: nil)
        }

        #expect(endpoints.reader.processClearRequest())
        try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                     timestamp: &timestamp,
                                     frames: nil)
        #expect(endpoints.writer.depthFrames == 960)
    }

    @Test("Playout buffer rejects a format with no bytes per frame")
    func playoutRejectsInvalidFormat() {
        #expect(throws: CircularBufferError.invalidFormat) {
            _ = try CircularBuffer.makeSPSC(length: 16_384,
                                            format: AudioStreamBasicDescription())
        }
    }

    @Test("A delayed clear remains pending until the reader resumes")
    func playoutClearRemainsPendingWhenReaderStalls() async throws {
        let format = try self.makeFormat()
        let endpoints = try self.makeEndpoints(format: format)
        let input = try self.makeBuffer(format: format)
        var timestamp = self.makeTimestamp()
        try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                     timestamp: &timestamp,
                                     frames: nil)

        // Crossing the diagnostic threshold must neither complete the wait nor impersonate the reader.
        let clearGeneration = endpoints.writer.requestClear()
        let completion = WaitState()
        await confirmation { warningObserved in
            await withCheckedContinuation { delayObserved in
                Task {
                    try await endpoints.writer.waitForClearAcknowledgement(
                        clearGeneration,
                        warningAfter: .milliseconds(10)) {
                        warningObserved()
                        delayObserved.resume()
                    }
                    await completion.set()
                }
            }
        }
        #expect(!(await completion.get()))

        // The writer remains blocked until the reader performs the clear.
        #expect(endpoints.reader.peek().frames == 960)
        #expect(throws: CircularBufferError.clearPending) {
            try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                         timestamp: &timestamp,
                                         frames: nil)
        }

        #expect(endpoints.reader.processClearRequest())
        await completion.wait()
        #expect(await completion.get())
        #expect(endpoints.reader.peek().frames == 0)
        try endpoints.writer.enqueue(buffer: &input.mutableAudioBufferList.pointee,
                                     timestamp: &timestamp,
                                     frames: nil)
        #expect(endpoints.writer.depthFrames == 960)
    }

    @Test("Large gap clears playout via the reader and preserves buffered future packets")
    func largeGapRecoveryPreservesFuturePackets() async throws {
        let decoder = RecordingAudioDecoder(format: try self.makeFormat())
        let handler = try AudioHandler(identifier: "large-gap-test",
                                       engine: StubPlayout(),
                                       decoder: decoder,
                                       measurement: nil,
                                       metricsSubmitter: nil,
                                       config: .init(jitterDepth: 0,
                                                     jitterMax: 1,
                                                     opusWindowSize: .twentyMs,
                                                     granularMetrics: false,
                                                     useNewJitterBuffer: true,
                                                     maxPlcThreshold: 3,
                                                     playoutBufferTime: 0,
                                                     slidingWindowTime: 1,
                                                     adaptive: false))
        let jitterBuffer = try self.makeJitterBuffer()
        handler.jitterBuffer = jitterBuffer
        let endpoints = try self.makeEndpoints(format: decoder.decodedFormat)
        let now = Date.now

        // Pre-gap audio is already queued for playout.
        let staleAudio = try self.makeBuffer(format: decoder.decodedFormat)
        var staleTimestamp = self.makeTimestamp()
        try endpoints.writer.enqueue(buffer: &staleAudio.mutableAudioBufferList.pointee,
                                     timestamp: &staleTimestamp,
                                     frames: nil)

        for sequence in [UInt64(100), 101, 102] {
            try jitterBuffer.write(item: EncodedAudioItem(sequenceNumber: sequence), from: now)
        }

        let anchor: EncodedAudioItem = try #require(jitterBuffer.read(from: now))
        #expect(anchor.sequenceNumber == 100)
        let clearGeneration = try #require(handler.checkForDiscontinuity(anchor,
                                                                         window: .twentyMs,
                                                                         when: now,
                                                                         lastUsedSequence: 1,
                                                                         playoutBuffer: endpoints.writer))
        #expect(decoder.resetCount == 1)

        // Recovery is not complete, and no post-gap audio may be queued, until the reader has acted.
        #expect(!endpoints.writer.isClearAcknowledged(clearGeneration))
        #expect(endpoints.reader.peek().frames == 960)
        #expect(throws: CircularBufferError.clearPending) {
            try endpoints.writer.enqueue(buffer: &staleAudio.mutableAudioBufferList.pointee,
                                         timestamp: &staleTimestamp,
                                         frames: nil)
        }

        #expect(endpoints.reader.processClearRequest())
        try await endpoints.writer.waitForClearAcknowledgement(clearGeneration,
                                                               warningAfter: .seconds(1))
        try endpoints.writer.enqueue(buffer: &staleAudio.mutableAudioBufferList.pointee,
                                     timestamp: &staleTimestamp,
                                     frames: nil)

        // Packets buffered behind the gap survive it, in order, without further resets.
        var lastUsedSequence = anchor.sequenceNumber
        for expectedSequence in [UInt64(101), UInt64(102)] {
            let item: EncodedAudioItem = try #require(jitterBuffer.read(from: now))
            #expect(item.sequenceNumber == expectedSequence)
            let clearGeneration = handler.checkForDiscontinuity(item,
                                                                window: .twentyMs,
                                                                when: now,
                                                                lastUsedSequence: lastUsedSequence,
                                                                playoutBuffer: endpoints.writer)
            #expect(clearGeneration == nil)
            lastUsedSequence = item.sequenceNumber
        }
        #expect(decoder.resetCount == 1)
    }

    // CMBufferQueue's callbacks erase the concrete item type.
    // swiftlint:disable force_cast
    private func makeJitterBuffer() throws -> JitterBuffer {
        let duration = CMTime(value: 20, timescale: 1_000)
        let handlers = CMBufferQueue.Handlers { builder in
            builder.compare {
                let first = $0 as! EncodedAudioItem
                let second = $1 as! EncodedAudioItem
                if first.sequenceNumber < second.sequenceNumber {
                    return .compareLessThan
                }
                if first.sequenceNumber > second.sequenceNumber {
                    return .compareGreaterThan
                }
                return .compareEqualTo
            }
            builder.getDecodeTimeStamp { ($0 as! EncodedAudioItem).timestamp }
            builder.getDuration { _ in duration }
            builder.getPresentationTimeStamp { ($0 as! EncodedAudioItem).timestamp }
            builder.getSize { ($0 as! EncodedAudioItem).data.count }
            builder.isDataReady { _ in true }
        }
        return try JitterBuffer(identifier: "large-gap-test",
                                metricsSubmitter: nil,
                                minDepth: 0,
                                capacity: 8,
                                handlers: handlers)
    }
    // swiftlint:enable force_cast

    private final class StubPlayout: AudioPlayout {
        func addPlayer(identifier: SourceIDType, node: AVAudioSourceNode) throws {}
        func removePlayer(identifier: SourceIDType) throws {}
    }

    private actor WaitState {
        private var value = false
        private var waiter: CheckedContinuation<Void, Never>?

        func set() {
            self.value = true
            self.waiter?.resume()
            self.waiter = nil
        }

        func get() -> Bool {
            self.value
        }

        func wait() async {
            guard !self.value else { return }
            await withCheckedContinuation { continuation in
                self.waiter = continuation
            }
        }
    }

    private final class EncodedAudioItem: JitterBuffer.JitterItem {
        let data: Data
        let sequenceNumber: UInt64
        let timestamp: CMTime

        init(sequenceNumber: UInt64) {
            self.data = Data([UInt8(sequenceNumber)])
            self.sequenceNumber = sequenceNumber
            self.timestamp = CMTime(value: CMTimeValue(sequenceNumber * 20), timescale: 1_000)
        }
    }

    private final class RecordingAudioDecoder: AudioDecoder {
        let decodedFormat: AVAudioFormat
        let encodedFormat: AVAudioFormat
        private(set) var resetCount = 0

        init(format: AVAudioFormat) {
            self.decodedFormat = format
            self.encodedFormat = format
        }

        func write(data: Data) throws -> AVAudioPCMBuffer {
            try self.makeBuffer(frames: 960)
        }

        func frames(data: Data) throws -> AVAudioFrameCount {
            960
        }

        func plc(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            try self.makeBuffer(frames: frames)
        }

        func reset() throws {
            self.resetCount += 1
        }

        private func makeBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.decodedFormat,
                                                frameCapacity: frames) else {
                throw "Couldn't create decoded audio buffer"
            }
            buffer.frameLength = frames
            return buffer
        }
    }
}

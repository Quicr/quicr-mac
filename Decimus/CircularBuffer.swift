// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreAudioTypes
import CTPCircularBuffer
import Synchronization

/// Possible errors raised by ``CircularBuffer``.
enum CircularBufferError: Error, Equatable {
    /// Failure to allocate the underlying buffer memory.
    case initFailed
    /// The supplied audio format cannot describe the buffer's contents.
    case invalidFormat
    /// The buffer is too small to hold the data offered to ``CircularBuffer/Writer/enqueue(buffer:timestamp:frames:)``.
    case bufferTooSmall
    /// A clear has been requested but not yet performed by the reader.
    case clearPending
}

/// State of a buffer operation, either on ``CircularBuffer/Reader/dequeue(frames:buffer:)``
/// or ``CircularBuffer/Reader/peek()``.
struct DequeueResult {
    /// The number of audio frames dequeued or available to be.
    let frames: UInt32
    /// The timestamp of the first audio frame out of the N dequeued or peeked frames.
    let timestamp: AudioTimeStamp
}

private final class CircularBufferStorage: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<TPCircularBuffer>
    private let format: UnsafeMutablePointer<AudioStreamBasicDescription>
    private let initialized: Bool

    init(length: UInt32, format: AudioStreamBasicDescription) throws {
        guard format.mBytesPerFrame > 0 else { throw CircularBufferError.invalidFormat }
        self.buffer = .allocate(capacity: 1)
        self.buffer.initialize(to: .init())
        self.format = .allocate(capacity: 1)
        self.format.initialize(to: format)

        guard _TPCircularBufferInit(self.buffer, length, MemoryLayout<TPCircularBuffer>.size) else {
            self.initialized = false
            throw CircularBufferError.initFailed
        }
        self.initialized = true
    }

    func clear() {
        TPCircularBufferClear(self.buffer)
    }

    func dequeue(frames: UInt32, buffer: inout AudioBufferList) -> DequeueResult {
        var inOutFrames = frames
        var timestamp = AudioTimeStamp()
        TPCircularBufferDequeueBufferListFrames(self.buffer,
                                                &inOutFrames,
                                                &buffer,
                                                &timestamp,
                                                self.format)
        return .init(frames: inOutFrames, timestamp: timestamp)
    }

    func enqueue(buffer: inout AudioBufferList,
                 timestamp: inout AudioTimeStamp,
                 frames: UInt32?) throws -> UInt32 {
        let copiedFrames = frames ?? buffer.mBuffers.mDataByteSize / self.format.pointee.mBytesPerFrame
        let copied = TPCircularBufferCopyAudioBufferList(self.buffer,
                                                         &buffer,
                                                         &timestamp,
                                                         frames ?? kTPCircularBufferCopyAll,
                                                         self.format)
        guard copied else { throw CircularBufferError.bufferTooSmall }
        return copiedFrames
    }

    func peek() -> DequeueResult {
        var timestamp = AudioTimeStamp()
        let available = TPCircularBufferPeek(self.buffer, &timestamp, self.format)
        return .init(frames: available, timestamp: timestamp)
    }

    deinit {
        if self.initialized {
            TPCircularBufferCleanup(self.buffer)
        }
        self.buffer.deinitialize(count: 1)
        self.buffer.deallocate()
        self.format.deinitialize(count: 1)
        self.format.deallocate()
    }
}

private final class CircularBufferState: Sendable {
    let storage: CircularBufferStorage
    let producedFrames = Atomic<UInt64>(0)
    let consumedFrames = Atomic<UInt64>(0)
    let clearRequested = Atomic<UInt64>(0)
    let clearAcknowledged = Atomic<UInt64>(0)

    init(storage: CircularBufferStorage) {
        self.storage = storage
    }

}

/// Swift wrapper for [`TPCircularBuffer`](https://github.com/michaeltyson/TPCircularBuffer),
/// split into a producing and a consuming half.
///
/// Emptying the buffer is a consumer-side operation, so a producer that needs the buffer emptied asks
/// for it with ``Writer/requestClear()`` and the consumer performs it in ``Reader/processClearRequest()``.
enum CircularBuffer {
    /// The two halves of one buffer.
    struct Endpoints: Sendable {
        let writer: Writer
        let reader: Reader
    }

    /// The producing half. Audio may only be enqueued from one thread at a time.
    final class Writer: Sendable {
        private static let acknowledgementPollInterval: Duration = .milliseconds(2)
        private let state: CircularBufferState

        fileprivate init(_ state: CircularBufferState) {
            self.state = state
        }

        /// Frames enqueued but not yet consumed by the reader.
        var depthFrames: UInt32 {
            let consumed = self.state.consumedFrames.load(ordering: .acquiring)
            let produced = self.state.producedFrames.load(ordering: .relaxed)
            guard produced > consumed else { return 0 }
            return UInt32(clamping: produced - consumed)
        }

        /// Enqueue timestamped audio frames from the provided buffer.
        /// - Parameter buffer AudioBufferList containing the data to enqueue.
        /// - Parameter timestamp Timestamp of this audio data.
        /// - Parameter frames Number of frames to enqueue from the buffer. Use nil to copy all.
        /// - Throws: ``CircularBufferError/clearPending`` while a requested clear is outstanding,
        ///           ``CircularBufferError/bufferTooSmall`` if too much data is provided.
        func enqueue(buffer: inout AudioBufferList,
                     timestamp: inout AudioTimeStamp,
                     frames: UInt32?) throws {
            guard self.isClearAcknowledged(self.state.clearRequested.load(ordering: .acquiring)) else {
                throw CircularBufferError.clearPending
            }
            let copiedFrames = try self.state.storage.enqueue(buffer: &buffer,
                                                              timestamp: &timestamp,
                                                              frames: frames)
            self.state.producedFrames.wrappingAdd(UInt64(copiedFrames), ordering: .relaxed)
        }

        /// Ask the reader to empty the buffer. ``enqueue(buffer:timestamp:frames:)`` throws
        /// ``CircularBufferError/clearPending`` until it has done so. Repeated or concurrent requests
        /// coalesce into the outstanding generation.
        /// - Returns: The generation the reader must acknowledge.
        func requestClear() -> UInt64 {
            let requested = self.state.clearRequested.load(ordering: .relaxed)
            guard self.isClearAcknowledged(requested) else { return requested }
            return self.state.clearRequested.wrappingAdd(1, ordering: .releasing).newValue
        }

        func isClearAcknowledged(_ generation: UInt64) -> Bool {
            self.state.clearAcknowledged.load(ordering: .acquiring) >= generation
        }

        /// Block until the reader clears.
        /// - Parameter generation: The clear request.
        /// - Parameter warningAfter: The diagnostic delay threshold.
        /// - Parameter onDelay: Called once if acknowledgement is still pending when polled after the threshold.
        /// - Throws: `CancellationError` if the waiting task is cancelled.
        func waitForClearAcknowledgement(_ generation: UInt64,
                                         warningAfter: Duration,
                                         onDelay: @Sendable () -> Void = {}) async throws {
            let clock = ContinuousClock()
            let warningDeadline = clock.now.advanced(by: warningAfter)
            var reportedDelay = false
            while !self.isClearAcknowledged(generation) {
                if !reportedDelay, clock.now >= warningDeadline {
                    reportedDelay = true
                    onDelay()
                }
                try await Task.sleep(for: Self.acknowledgementPollInterval,
                                     tolerance: Self.acknowledgementPollInterval,
                                     clock: clock)
            }
            try Task.checkCancellation()
        }
    }

    /// The consuming half. Audio may only be dequeued from one thread at a time.
    final class Reader: Sendable {
        private let state: CircularBufferState

        fileprivate init(_ state: CircularBufferState) {
            self.state = state
        }

        /// Consume a clear request from the writer. Should call on all reads.
        /// - Returns: True if the buffer was emptied in response to a clear request.
        @discardableResult
        func processClearRequest() -> Bool {
            let requested = self.state.clearRequested.load(ordering: .acquiring)
            guard requested > self.state.clearAcknowledged.load(ordering: .relaxed) else {
                return false
            }

            self.state.storage.clear()
            let produced = self.state.producedFrames.load(ordering: .relaxed)
            self.state.consumedFrames.store(produced, ordering: .releasing)
            self.state.clearAcknowledged.store(requested, ordering: .releasing)
            return true
        }

        /// Dequeue the given number of frames into the provided buffer.
        /// - Parameter frames Attempt to dequeue up to this many frames.
        /// - Parameter buffer The buffer to dequeue audio into.
        /// - Returns ``DequeueResult`` reporting what has been dequeued into the provided buffer.
        func dequeue(frames: UInt32, buffer: inout AudioBufferList) -> DequeueResult {
            let result = self.state.storage.dequeue(frames: frames, buffer: &buffer)
            self.state.consumedFrames.wrappingAdd(UInt64(result.frames), ordering: .releasing)
            return result
        }

        /// Peek at available data.
        /// - Returns ``DequeueResult`` showing number of available frames and timestamp of first frame.
        func peek() -> DequeueResult {
            self.state.storage.peek()
        }
    }

    /// Create a single-producer, single-consumer buffer for the given format & capacity.
    /// - Parameter length Allocate at least this much space.
    /// - Parameter format The format of the audio the buffer will contain.
    /// - Throws: ``CircularBufferError/invalidFormat`` for a format with no frame size,
    ///           ``CircularBufferError/initFailed`` on underlying allocation failure.
    static func makeSPSC(length: UInt32, format: AudioStreamBasicDescription) throws -> Endpoints {
        let storage = try CircularBufferStorage(length: length, format: format)
        let state = CircularBufferState(storage: storage)
        return .init(writer: .init(state), reader: .init(state))
    }
}

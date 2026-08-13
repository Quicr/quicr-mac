// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreAudioTypes
import CTPCircularBuffer
import Synchronization

/// Possible errors raised by `CircularBuffer`.
enum CircularBufferError: Error, Equatable {
    /// Failure to initialize/allocate underlying buffer memory.
    case initFailed
    /// The buffer is too small to support the data on ``CircularBuffer/enqueue(buffer:timestamp:frames:)``
    case bufferTooSmall
    /// A clear has been requested but not yet performed by the reader.
    case clearPending
}

/// State of a buffer operation, either on ``CircularBuffer/dequeue(frames:buffer:)`` or ``CircularBuffer/peek()``.
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
        self.buffer = .allocate(capacity: 1)
        self.buffer.initialize(to: .init())
        self.format = .allocate(capacity: 1)
        self.format.initialize(to: format)

        guard format.mBytesPerFrame > 0,
              _TPCircularBufferInit(self.buffer, length, MemoryLayout<TPCircularBuffer>.size) else {
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

/// Swift wrapper for [`TPCircularBuffer`](https://github.com/michaeltyson/TPCircularBuffer).
final class CircularBuffer: Sendable {
    private let storage: CircularBufferStorage

    /// Create a buffer for the given format & capacity.
    /// - Parameter length Allocate at least this much space.
    /// - Parameter format The format of the audio the buffer will contain.
    /// - Throws: ``CircularBufferError/initFailed`` on underlying failure.
    init(length: UInt32, format: AudioStreamBasicDescription) throws {
        self.storage = try .init(length: length, format: format)
    }

    /// Clear the buffer.
    func clear() {
        self.storage.clear()
    }

    /// Dequeue the given number of frames into the provided buffer.
    /// - Parameter frames Attempt to dequeue up to this many frames.
    /// - Parameter buffer The buffer to dequeue audio into.
    /// - Returns ``DequeueResult`` reporting what has been dequeued into the provided buffer.
    func dequeue(frames: UInt32, buffer: inout AudioBufferList) -> DequeueResult {
        self.storage.dequeue(frames: frames, buffer: &buffer)
    }

    /// Enqueue timestamped audio frames from the provided buffer.
    /// - Parameter buffer AudioBufferList containing the data to encode.
    /// - Parameter timestamp Timestamp of this audio data.
    /// - Parameter frames Number of frames to enqueue from the buffer. Use nil to copy all.
    /// - Throws: ``CircularBufferError/bufferTooSmall`` if too much data is provided.
    func enqueue(buffer: inout AudioBufferList, timestamp: inout AudioTimeStamp, frames: UInt32?) throws {
        _ = try self.storage.enqueue(buffer: &buffer, timestamp: &timestamp, frames: frames)
    }

    /// Peek at available data.
    /// - Returns ``DequeueResult`` showing number of available frames and timestamp of first frame.
    func peek() -> DequeueResult {
        self.storage.peek()
    }
}

// Type safe read/write ops.
extension CircularBuffer {
    struct Endpoints: Sendable {
        let writer: Writer
        let reader: Reader
    }

    final class Writer: Sendable {
        private let state: CircularBufferState

        fileprivate init(_ state: CircularBufferState) {
            self.state = state
        }

        var depthFrames: UInt32 {
            let produced = self.state.producedFrames.load(ordering: .relaxed)
            let consumed = self.state.consumedFrames.load(ordering: .acquiring)
            guard produced > consumed else { return 0 }
            return UInt32(clamping: produced - consumed)
        }

        func enqueue(buffer: inout AudioBufferList,
                     timestamp: inout AudioTimeStamp,
                     frames: UInt32?) throws {
            guard self.state.clearRequested.load(ordering: .acquiring) ==
                    self.state.clearAcknowledged.load(ordering: .acquiring) else {
                throw CircularBufferError.clearPending
            }
            let copiedFrames = try self.state.storage.enqueue(buffer: &buffer,
                                                              timestamp: &timestamp,
                                                              frames: frames)
            self.state.producedFrames.wrappingAdd(UInt64(copiedFrames), ordering: .relaxed)
        }

        /// Ask the reader to clear the buffer. ``enqueue(buffer:timestamp:frames:)`` throws
        /// ``CircularBufferError/clearPending`` until it has done so.
        /// - Returns: The generation the reader must acknowledge.
        func requestClear() -> UInt64 {
            let requested = self.state.clearRequested.load(ordering: .relaxed)
            guard requested == self.state.clearAcknowledged.load(ordering: .acquiring) else {
                return requested
            }
            return self.state.clearRequested.wrappingAdd(1, ordering: .releasing).newValue
        }

        func isClearAcknowledged(_ generation: UInt64) -> Bool {
            self.state.clearAcknowledged.load(ordering: .acquiring) == generation
        }

        func waitForClearAcknowledgement(_ generation: UInt64) async -> Bool {
            while !self.isClearAcknowledged(generation) {
                do {
                    try await Task.sleep(for: .milliseconds(1), clock: .continuous)
                } catch {
                    return false
                }
            }
            return !Task.isCancelled
        }
    }

    final class Reader: Sendable {
        private let state: CircularBufferState

        fileprivate init(_ state: CircularBufferState) {
            self.state = state
        }

        @discardableResult
        func processClearRequest() -> Bool {
            let requested = self.state.clearRequested.load(ordering: .acquiring)
            guard requested != self.state.clearAcknowledged.load(ordering: .relaxed) else {
                return false
            }

            self.state.storage.clear()
            let produced = self.state.producedFrames.load(ordering: .relaxed)
            self.state.consumedFrames.store(produced, ordering: .releasing)
            self.state.clearAcknowledged.store(requested, ordering: .releasing)
            return true
        }

        func dequeue(frames: UInt32, buffer: inout AudioBufferList) -> DequeueResult {
            let result = self.state.storage.dequeue(frames: frames, buffer: &buffer)
            self.state.consumedFrames.wrappingAdd(UInt64(result.frames), ordering: .releasing)
            return result
        }

        func peek() -> DequeueResult {
            self.state.storage.peek()
        }
    }

    static func makeSPSC(length: UInt32, format: AudioStreamBasicDescription) throws -> Endpoints {
        let storage = try CircularBufferStorage(length: length, format: format)
        let state = CircularBufferState(storage: storage)
        return .init(writer: .init(state), reader: .init(state))
    }
}

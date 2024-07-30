import CoreAudioTypes
import CTPCircularBuffer

enum CircularBufferError: Error {
    case initFailed
    case bufferTooSmall
}

struct DequeueResult {
    let frames: UInt32
    let timestamp: AudioTimeStamp
}

/// Swift wrapper for TPCircularBuffer.
class CircularBuffer {
    private var buffer = TPCircularBuffer()
    private var format: AudioStreamBasicDescription

    /// Create a buffer for the given format & capacity.
    /// - Parameter length Allocate at least this much space.
    /// - Parameter format The format of the audio the buffer will contain.
    init(length: UInt32, format: AudioStreamBasicDescription) throws {
        let success = _TPCircularBufferInit(&self.buffer, length, MemoryLayout<TPCircularBuffer>.size)
        guard success else { throw CircularBufferError.initFailed }
        self.format = format
    }

    /// Dequeue the given number of frames into the provided buffer.
    /// - Parameter frames Attempt to dequeue up to this many frames.
    /// - Parameter buffer The buffer to dequeue audio into.
    /// - Returns DequeueResult giving number of actually dequeued frames, and timestamp.
    func dequeue(frames: UInt32, buffer: inout AudioBufferList) -> DequeueResult {
        var inOutFrames = frames
        var timestamp = AudioTimeStamp()
        TPCircularBufferDequeueBufferListFrames(&self.buffer,
                                                &inOutFrames,
                                                &buffer,
                                                &timestamp,
                                                &self.format)
        return .init(frames: inOutFrames, timestamp: timestamp)
    }

    /// Enqueue timestamped audio frames from the provided buffer.
    /// - Parameter buffer AudioBufferList containing the data to encode.
    /// - Parameter timestamp Timestamp of this audio data.
    /// - Parameter frames Number of frames to enqueue from the buffer. Use nil to copy all.
    func enqueue(buffer: inout AudioBufferList, timestamp: inout AudioTimeStamp, frames: UInt32?) throws {
        let copied = TPCircularBufferCopyAudioBufferList(&self.buffer,
                                                         &buffer,
                                                         &timestamp,
                                                         frames ?? kTPCircularBufferCopyAll,
                                                         &self.format)
        guard copied else { throw CircularBufferError.bufferTooSmall }
    }

    /// Peek at available data.
    /// - Returns DequeueResult showing number of available frames and timestamp of first frame.
    func peek() -> DequeueResult {
        var timestamp = AudioTimeStamp()
        let available = TPCircularBufferPeek(&self.buffer, &timestamp, &self.format)
        return .init(frames: available, timestamp: timestamp)
    }

    deinit {
        TPCircularBufferCleanup(&self.buffer)
    }
}

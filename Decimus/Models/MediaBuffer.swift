struct MediaBuffer {
    let identifier: UInt32
    let buffer: UnsafeRawBufferPointer
    let timestampMs: UInt32

    init(identifier: UInt32, other: MediaBuffer) {
        self.identifier = identifier
        buffer = other.buffer
        timestampMs = other.timestampMs
    }

    init(identifier: UInt32, buffer: UnsafeRawBufferPointer, timestampMs: UInt32) {
        self.identifier = identifier
        self.buffer = buffer
        self.timestampMs = timestampMs
    }
}

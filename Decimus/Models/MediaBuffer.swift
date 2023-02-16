/// Represents some media data.
struct MediaBuffer {
    /// Pointer to the media data.
    let buffer: UnsafeRawBufferPointer
    /// Timestamp of this media data, in milliseconds.
    let timestampMs: UInt32
}

/// Represents some media data from a source.
struct MediaBufferFromSource {
    /// The source identifier this media comes from.
    let source: UInt32
    /// The media data.
    let media: MediaBuffer
}

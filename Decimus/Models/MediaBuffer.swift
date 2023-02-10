struct MediaBuffer {
    let identifier: UInt32
    let buffer: UnsafePointer<UInt8>
    let length: Int
    let timestampMs: UInt32
}

import Foundation
import os

/// Possible errors from BufferAllocator.
enum BufferAllocatorError: Error {
    enum BlockType {
        case alloc
        case header
    }
    case tooLarge(_: BlockType)
    case failedToAllocate
    case badPointer
}

/// Custom allocator for a buffer with data prefixed by headers.
class BufferAllocator {
    private let preAllocateHdrSize: Int
    private let preAllocatedBuffer: UnsafeRawBufferPointer
    private var allocator: CFAllocator?

    private var firstHeaderPtr: UnsafeRawPointer
    private var frameBufferView: UnsafeRawBufferPointer
    private let lock = OSAllocatedUnfairLock()

    /// Create a new buffer allocator.
    /// - Parameter preAllocateSize The total size to allocate, in bytes.
    /// - Parameter preAllocateHdrSize The subset of preAllocateSize to reserve for header space, in bytes.
    init(preAllocateSize: Int, preAllocateHdrSize: Int) throws {
        let maxSize = 4 * 1024 * 1024
        guard preAllocateSize <= maxSize else {
            throw BufferAllocatorError.tooLarge(.alloc)
        }
        guard preAllocateHdrSize < preAllocateSize else {
            throw BufferAllocatorError.tooLarge(.header)
        }

        // Allocate the buffer.
        self.preAllocatedBuffer = .init(.allocate(byteCount: preAllocateSize,
                                                  alignment: MemoryLayout<UInt8>.alignment))
        guard self.preAllocatedBuffer.count == preAllocateSize,
              let baseAddress = self.preAllocatedBuffer.baseAddress else {
            throw BufferAllocatorError.failedToAllocate
        }

        // Set the header pointer to work backwards from, and the frame buffer
        // to work forwards from.
        self.firstHeaderPtr = baseAddress.advanced(by: preAllocateHdrSize)
        self.frameBufferView = .init(start: self.firstHeaderPtr,
                                     count: 0)
        self.preAllocateHdrSize = preAllocateHdrSize
    }

    deinit {
        self.preAllocatedBuffer.deallocate()
    }

    /// Return the CFAllocator instance that calls this allocator.
    /// - Returns The CFAllocator instance.
    func getAllocator() throws -> CFAllocator {
        if let allocator = self.allocator {
            return allocator
        }

        // Create a CFAllocator representation of the allocator.
        var context = CFAllocatorContext()
        CFAllocatorGetContext(kCFAllocatorDefault,
                              &context)
        context.allocate = self.allocate
        context.deallocate = self.deallocate

        // Get unmanaged reference to self.
        let pointerToSelf = Unmanaged.passUnretained(self).toOpaque()
        context.info = pointerToSelf
        guard let unmanaged = CFAllocatorCreate(kCFAllocatorDefault, &context) else {
            throw "Allocation failure"
        }
        let allocator = unmanaged.takeRetainedValue()
        self.allocator = allocator
        return allocator
    }

    /// Get a pointer to a buffer at the head of the buffer (ahead of previous data or headers).
    /// - Parameter size Size to allocate in bytes.
    /// - Returns Buffer to fill, or nil if it couldn't be provided.
    func allocateBufferHeader(_ size: Int) -> UnsafeMutableRawBufferPointer? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard getAvailableHeaderSize() >= size else {
            return nil
        }
        self.firstHeaderPtr = self.firstHeaderPtr.advanced(by: -size)
        return .init(start: .init(mutating: self.firstHeaderPtr), count: size)
    }

    /// Get a reference to the currently written headers and data.
    /// - Returns The buffer.
    func retrieveFullBufferPointer() throws -> UnsafeRawBufferPointer {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let frameBufferPtr = self.frameBufferView.baseAddress else {
            throw "Bad lookup"
        }
        return .init(start: self.firstHeaderPtr,
                     count: (frameBufferPtr - self.firstHeaderPtr) + self.frameBufferView.count)
    }

    private let allocate: CFAllocatorAllocateCallBack = { allocSize, _, info in
        assert(info != nil)
        guard let info = info else { return nil }
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        // Ensure we have enough space for this.
        let availableSpace = allocator.preAllocatedBuffer.count - allocator.preAllocateHdrSize - allocator.frameBufferView.count
        guard allocSize <= availableSpace else {
            return nil
        }
        allocator.lock.lock()
        defer { allocator.lock.unlock() }
        let base = allocator.frameBufferView.baseAddress
        let newWrittenBytes = allocator.frameBufferView.count + allocSize
        allocator.frameBufferView = UnsafeRawBufferPointer(start: base,
                                                           count: newWrittenBytes)
        return .init(mutating: base)
    }

    private let deallocate: CFAllocatorDeallocateCallBack = { _, info in
        assert(info != nil)
        guard let info = info else { return }
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        allocator.lock.withLock {
            if let frameBufferPtr = allocator.frameBufferView.baseAddress {
                allocator.firstHeaderPtr = frameBufferPtr
            }
            allocator.frameBufferView = .init(start: allocator.firstHeaderPtr, count: 0)
        }
    }

    private func getAvailableHeaderSize() -> Int {
        guard let preAllocatedBuffer = self.preAllocatedBuffer.baseAddress else {
            // This should never happen.
            assert(false)
            return 0
        }
        guard self.firstHeaderPtr > preAllocatedBuffer else {
            // This should never happen.
            assert(false)
            return 0
        }
        return self.firstHeaderPtr - preAllocatedBuffer
    }
}

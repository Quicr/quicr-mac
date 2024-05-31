import Foundation
import os
import OrderedCollections

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
/// Deallocates MUST occur in reverse order of allocations.
class BufferAllocator {
    private let preAllocateHdrSize: Int
    private let preAllocatedBuffer: UnsafeRawBufferPointer
    private var allocator: CFAllocator?

    private var firstHeaderPtr: UnsafeRawPointer
    private var frameBufferView: UnsafeRawBufferPointer
    private let lock = OSAllocatedUnfairLock()
    private var blocks: OrderedDictionary<UnsafeRawPointer, Int> = [:]

    // CFAllocate callback implementation.
    private let allocate: CFAllocatorAllocateCallBack = { allocSize, _, info in
        // Unwrap.
        guard let info = info else {
            assert(false)
            return nil
        }

        // Resolve info to ourself.
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        allocator.lock.lock()
        defer { allocator.lock.unlock() }

        // Ensure we have enough space for this request.
        let availableSpace = allocator.preAllocatedBuffer.count
            - allocator.preAllocateHdrSize
            - allocator.frameBufferView.count
        guard allocSize <= availableSpace else { return nil }

        // Unwrap optional address.
        guard let base = allocator.frameBufferView.baseAddress else {
            assert(false)
            return nil
        }

        // Resize frame buffer to include this allocation.
        let existingDataBytes = allocator.frameBufferView.count
        let newWrittenBytes = existingDataBytes + allocSize
        allocator.frameBufferView = UnsafeRawBufferPointer(start: base,
                                                           count: newWrittenBytes)

        // Store and return this point to be written to by the caller.
        let newPtr = base + existingDataBytes
        allocator.blocks[newPtr] = allocSize
        return .init(mutating: newPtr)
    }

    // CFDeallocate callback implementation.
    private let deallocate: CFAllocatorDeallocateCallBack = { ptr, info in
        // Unwrap optionals.
        guard let info = info,
              let ptr = ptr else {
            assert(false)
            return
        }

        // Resolve info to ourself.
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        allocator.lock.lock()
        defer { allocator.lock.unlock() }

        // "Deallocate" this block.
        assert(allocator.blocks.count > 0)
        let block = allocator.blocks.removeLast()
        assert(block.key == ptr)
        guard let base = allocator.frameBufferView.baseAddress else {
            assert(false)
            return
        }
        allocator.frameBufferView = .init(start: base, count: allocator.frameBufferView.count - block.value)
        if allocator.blocks.isEmpty {
            // When empty, clear headers.
            allocator.firstHeaderPtr = base
            assert(allocator.firstHeaderPtr == base)
            assert(base == allocator.preAllocatedBuffer.baseAddress! + allocator.preAllocateHdrSize)
        }
    }

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
        let dataStartPtr = baseAddress.advanced(by: preAllocateHdrSize)
        self.firstHeaderPtr = dataStartPtr
        self.frameBufferView = .init(start: dataStartPtr,
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
        guard size > 0 else { return nil }
        self.lock.lock()
        defer { self.lock.unlock() }

        // Unwrap.
        guard let preAllocatedBuffer = self.preAllocatedBuffer.baseAddress else {
            assert(false)
            return nil
        }

        // Ensure we have enough header space.
        let availableSpace = self.firstHeaderPtr - preAllocatedBuffer
        guard availableSpace >= size else {
            return nil
        }

        // Move the header pointer backwards.
        self.firstHeaderPtr = self.firstHeaderPtr.advanced(by: -size)
        return .init(start: .init(mutating: self.firstHeaderPtr), count: size)
    }

    /// Retreive the written data - all written headers followed by written data.
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

    #if os(iOS) && !targetEnvironment(macCatalyst)
    func deallocateAll() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.blocks.removeAll()
        self.frameBufferView = .init(start: self.preAllocatedBuffer.baseAddress! + self.preAllocateHdrSize, count: 0)
        self.firstHeaderPtr = self.frameBufferView.baseAddress!
    }
    #endif
}

import Foundation

enum BlockType {
    case alloc
    case header
}

enum BufferAllocatorError: Error {
    case tooLarge(_: BlockType)
    case failedToAllocate
}

class BufferAllocator {
    private let preAllocateSize: Int
    private let preAllocateHdrSize: Int
    private let preAllocatedBuffer: UnsafeMutableRawBufferPointer

    private var frameBufferSize = 0
    private var frameBufferPtr: UnsafeMutableRawBufferPointer
    private var firstHeaderPtr: UnsafeMutableRawPointer

    private let extendedAllocate: CFAllocatorAllocateCallBack = { allocSize, _, info in
        assert(info != nil)
        guard let info = info else { return nil }
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        guard allocSize <= allocator.preAllocateSize - allocator.preAllocateHdrSize else {
            return nil
        }
        return allocator.frameBufferPtr.baseAddress
    }

    private let extendedDeallocate: CFAllocatorDeallocateCallBack = { _, info in
        assert(info != nil)
        guard let info = info else { return }
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        guard let baseAddress = allocator.frameBufferPtr.baseAddress else {
            assert(false)
            return
        }
        allocator.firstHeaderPtr = baseAddress
        allocator.frameBufferSize = 0
    }

    init(preAllocateSize: Int, preAllocateHdrSize: Int) throws {
        let maxSize = 4 * 1024 * 1024
        guard preAllocateSize <= maxSize else {
            throw BufferAllocatorError.tooLarge(.alloc)
        }
        guard preAllocateHdrSize < preAllocateSize else {
            throw BufferAllocatorError.tooLarge(.header)
        }
        self.preAllocateSize = preAllocateSize
        self.preAllocateHdrSize = preAllocateHdrSize
        self.preAllocatedBuffer = .allocate(byteCount: self.preAllocateSize,
                                            alignment: MemoryLayout<UInt8>.alignment)
        guard self.preAllocatedBuffer.count == self.preAllocateSize,
              let baseAddress = self.preAllocatedBuffer.baseAddress else {
            throw BufferAllocatorError.failedToAllocate
        }
        self.frameBufferPtr = self.preAllocatedBuffer
        self.firstHeaderPtr = baseAddress
    }

    func allocateBufferHeader(_ size: Int) -> UnsafeMutableRawPointer? {
        guard getAvailableHeaderSize() >= size else {
            self.firstHeaderPtr = self.firstHeaderPtr.advanced(by: -size)
            return self.firstHeaderPtr
        }
        return nil
    }

    private func getAvailableHeaderSize() -> Int {
        guard let preAllocatedBuffer = self.preAllocatedBuffer.baseAddress else {
            assert(false)
            return 0
        }
        guard self.firstHeaderPtr > preAllocatedBuffer else {
            return 0
        }
        return self.firstHeaderPtr - preAllocatedBuffer
    }

    func getAllocator() -> CFAllocator {
        var context = CFAllocatorContext()
        context.allocate = self.extendedAllocate
        context.deallocate = self.extendedDeallocate
        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        context.info = unmanaged
        return CFAllocatorCreate(nil, &context).takeRetainedValue()
    }

    // *bufferPtr = firstHeaderPtr;
    // *length = (frameBufferPtr - firstHeaderPtr) + frameBufferSize;

    func retrieveFullBufferPointer() -> UnsafeRawBufferPointer {
        guard let baseAddress = self.frameBufferPtr.baseAddress else {
            return .init(start: nil, count: 0)
        }
        .init(start: self.firstHeaderPtr, count: (baseAddress - self.firstHeaderPtr) + self.frameBufferSize)
    }
}

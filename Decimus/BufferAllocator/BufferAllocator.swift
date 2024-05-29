import Foundation

// Possible errors from BufferAllocator.
enum BufferAllocatorError: Error {
    enum BlockType {
        case alloc
        case header
    }
    case tooLarge(_: BlockType)
    case failedToAllocate
    case badPointer
}

// Custom preallocated buffer.
class BufferAllocator {
    private let preAllocateSize: Int
    private let preAllocateHdrSize: Int
    private let preAllocatedBuffer: UnsafeRawBufferPointer

    private var firstHeaderPtr: UnsafeRawBufferPointer
    private var frameBufferView: UnsafeRawBufferPointer

    private let allocate: CFAllocatorAllocateCallBack = { allocSize, _, info in
        assert(info != nil)
        guard let info = info else { return nil }
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        guard allocSize <= allocator.preAllocateSize - allocator.preAllocateHdrSize else {
            return nil
        }
        allocator.frameBufferView = .init(rebasing: allocator.frameBufferView[0..<allocSize])
        return .init(mutating: allocator.frameBufferView.baseAddress)
    }

    private let deallocate: CFAllocatorDeallocateCallBack = { _, info in
        assert(info != nil)
        guard let info = info else { return }
        let allocator = Unmanaged<BufferAllocator>.fromOpaque(info).takeUnretainedValue()
        allocator.firstHeaderPtr = .init
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
        self.firstHeaderPtr = baseAddress.advanced(by: preAllocateHdrSize)
        self.frameBufferPtr = self.firstHeaderPtr
    }

    deinit {
        print("BufferAllocator deinit")
        self.preAllocatedBuffer.deallocate()
    }

    func allocateBufferHeader(_ size: Int) -> UnsafeMutableRawPointer? {
        guard getAvailableHeaderSize() >= size else {
            return nil
        }
        self.firstHeaderPtr = self.firstHeaderPtr.advanced(by: -size)
        return self.firstHeaderPtr
    }

    func retrieveFullBufferPointer() throws -> UnsafeRawBufferPointer {
        return .init(start: self.firstHeaderPtr,
                     count: (self.frameBufferPtr - self.firstHeaderPtr) + self.frameBufferSize)
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
}

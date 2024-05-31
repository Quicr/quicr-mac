@testable import Decimus
import XCTest

final class TestBufferAllocator: XCTestCase {
    func testBufferAllocator() throws {
        let dataSize = 300
        let headerSize = 200
        let bufferAllocator = try BufferAllocator(preAllocateSize: dataSize + headerSize,
                                                  preAllocateHdrSize: headerSize)
        
        // Get the CF allocator.
        let cfAllocator = try bufferAllocator.getAllocator()
        
        // Allocate some data.
        let data1Value: Int32 = 1
        guard let data1 = CFAllocatorAllocate(cfAllocator, dataSize / 2, 0) else {
            XCTFail()
            return
        }
        memset(data1, data1Value, dataSize / 2)
        let checkData1 = UnsafeRawBufferPointer(start: data1, count: dataSize / 2)
        XCTAssert(checkData1.allSatisfy{ $0 == data1Value })
        
        // Allocate a header.
        let header1Value: Int32 = 2
        guard let header1 = bufferAllocator.allocateBufferHeader(headerSize / 2) else {
            XCTFail()
            return
        }
        memset(header1.baseAddress, header1Value, headerSize / 2)
        XCTAssert(header1.allSatisfy{ $0 == header1Value })
        
        // Allocate more data.
        let data2Value: Int32 = 3
        guard let data2 = CFAllocatorAllocate(cfAllocator, dataSize / 2, 0) else {
            XCTFail()
            return
        }
        memset(data2, data2Value, dataSize / 2)
        let checkData2 = UnsafeRawBufferPointer(start: data2, count: dataSize / 2)
        XCTAssert(checkData2.allSatisfy{ $0 == data2Value })
        
        // Allocate another header.
        let header2Value: Int32 = 4
        guard let header2 = bufferAllocator.allocateBufferHeader(headerSize / 2) else {
            XCTFail()
            return
        }
        memset(header2.baseAddress, header2Value, headerSize / 2)
        XCTAssert(header2.allSatisfy{ $0 == header2Value })
        
        // More data should fail.
        let data3 = CFAllocatorAllocate(cfAllocator, 1, 0)
        XCTAssertNil(data3);
        
        // Another header should fail.
        let header3 = bufferAllocator.allocateBufferHeader(1)
        XCTAssertNil(header3)

        // Full buffer pointer should go: header2, header1, data1, data2.
        let fullBuffer = try bufferAllocator.retrieveFullBufferPointer()
        XCTAssertEqual(fullBuffer.count, dataSize + headerSize)
        guard let ptr = fullBuffer.baseAddress else {
            XCTFail()
            return
        }
        
        // Check the different parts.
        let getHeader2 = UnsafeRawBufferPointer(start: ptr,
                                                count: headerSize / 2)
        var offset = getHeader2.count
        XCTAssert(getHeader2.allSatisfy { $0 == header2Value })
        let getHeader1 = UnsafeRawBufferPointer(start: ptr + offset,
                                                count: headerSize / 2)
        XCTAssert(getHeader1.allSatisfy { $0 == header1Value })
        
        offset += getHeader1.count
        let getData1 = UnsafeRawBufferPointer(start: ptr + offset,
                                              count: dataSize / 2)
        XCTAssert(getData1.allSatisfy { $0 == data1Value })
        
        offset += getData1.count
        let getData2 = UnsafeRawBufferPointer(start: ptr + offset,
                                              count: dataSize / 2)
        XCTAssert(getData2.allSatisfy { $0 == data2Value })
    }
}

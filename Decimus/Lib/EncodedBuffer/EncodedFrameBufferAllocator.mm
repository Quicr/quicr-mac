//
//  BufferAllocator.m
//  Decimus
//
//  Created by Scott Henning on 7/25/23.
//

#import <Foundation/Foundation.h>
#import "EncodedFrameBufferAllocator.h"
#include "ExtBufferAllocator.h"

#ifdef __cplusplus
#include <inttypes.h>
#include <iostream>
#endif

@implementation BufferAllocator

- (instancetype) init: (size_t) preAllocSize hdrSize: (size_t) preAllocHdrSize {
    self = [super init];
    if (self) {
        extBufferAllocatorPtr = new ExtBufferAllocator(preAllocSize, preAllocHdrSize);
        NSLog(@"init: ext buffer ptr %p", extBufferAllocatorPtr);
    }
    return self;
}

- (void) dealloc {
    if (extBufferAllocatorPtr) {
        delete extBufferAllocatorPtr;
    }
   // CFRelease(allocatorRef);
}

- (CFAllocatorRef)allocator {
    CFAllocatorGetContext(kCFAllocatorDefault, &context);
    context.version = 0;
    context.allocate = extBufferAllocatorPtr->_extendedAllocate;
    context.deallocate = extBufferAllocatorPtr->_extendedDeallocate;
    context.info = extBufferAllocatorPtr;
    allocatorRef =CFAllocatorCreate(kCFAllocatorDefault, &context);
    return allocatorRef;
}

- (void *) allocateBufferHeader: (size_t) length {
    NSLog(@"allocateBufferHeader: ext buffer ptr %p", extBufferAllocatorPtr);
    return extBufferAllocatorPtr->allocateBufferHeader(length);
}
    
- (void) retrieveFullBufferPointer: (void **) fullBufferPtr len: (size_t *) lengthPtr {
    extBufferAllocatorPtr->retrieveFullBufferPointer(fullBufferPtr, lengthPtr);
}
@end

/*
 * Allocate a reusable buffer.
 *
 *   |        <----------- preAllocateSize ------------->              |
 *                 |<--- hdrSize --->|
 *   +-----------------------------------------------------------------+
 *   | {blank}     | hdr2 | hdr1     | buffer            | {blank}.... |
 *   +-----------------------------------------------------------------+
 *                                   ^
 *                                   |
 *                                   frameBufferPtr
 *
 * Supply a CFAllocatorRef that can be used in block buffer allocation.
 * Pre-allocate this buffer and reuse it. The pre-allocated buffer size
 * and maximum header size are used to size the overall buffer and
 * header offset.
 */
ExtBufferAllocator::ExtBufferAllocator(std::size_t preAllocateSize,
                                       std::size_t preAllocateHdrSize) :
                                        preAllocateSize(preAllocateSize),
                                        preAllocateHdrSize(preAllocateHdrSize)
{
    if (preAllocateSize <= 4ul * 1024 * 1024) { // 4M max
        preAllocatedBuffer = (std::uint8_t *)malloc(preAllocateSize);
        if (preAllocatedBuffer == nullptr) {
            std::cerr << "BufferAllocator() - preallocation erro" << std::endl;
        }
        frameBufferPtr = preAllocatedBuffer;
        frameBufferSize = 0;
        firstHeaderPtr = preAllocatedBuffer;
        
        if (preAllocateHdrSize < preAllocateSize) {
            frameBufferPtr = preAllocatedBuffer + preAllocateHdrSize;
            firstHeaderPtr = frameBufferPtr;
            NSLog(@"ExtBufferAllocator() - [%p]->[%p:[[%p/%lu] -> [%ld] -> [%p/%lu]]",
                  this,
                  preAllocatedBuffer,
                  firstHeaderPtr, preAllocateHdrSize,
                  frameBufferPtr - firstHeaderPtr,
                  frameBufferPtr, preAllocateSize);
        } else {
            std::cerr << "BufferAllocate() - preallocate header size invalid" << std::endl;
        }
    } else {
        std::cerr << "BufferAllocator() - preallocation size too large" << std::endl;
    }
}

ExtBufferAllocator::~ExtBufferAllocator() {
    free(preAllocatedBuffer);
}

void ExtBufferAllocator::resetBuffers() {
    firstHeaderPtr = frameBufferPtr;
    frameBufferSize = 0;
}

void *ExtBufferAllocator::_extendedAllocate(CFIndex allocSize, CFOptionFlags hint, void *info) {
    auto extBufferAllocatorPtr = (ExtBufferAllocator *)info;
    NSLog(@"_extendedAllocate: ext buffer ptr [%p/%lu]", extBufferAllocatorPtr, allocSize);

    if (extBufferAllocatorPtr) {
        return extBufferAllocatorPtr->allocateBuffer(allocSize);
    }
    return nullptr;
}

void ExtBufferAllocator::_extendedDeallocate(void *ptr, void *info) {
    // reset header pointer and sizes
    auto extBufferAllocatorPtr = (ExtBufferAllocator *)info;
    NSLog(@"_extendedDeallocate: ext buffer ptr %p", extBufferAllocatorPtr);
    if (extBufferAllocatorPtr) {
        extBufferAllocatorPtr->resetBuffers();
    }
}

void *ExtBufferAllocator::allocateBuffer(std::size_t bufferSize) {
    if (bufferSize <= (preAllocateSize - preAllocateHdrSize)) {
        frameBufferSize = bufferSize;
        NSLog(@"allocateBuffer: buffer ptr [%p/%lu]", frameBufferPtr, frameBufferSize);
        return frameBufferPtr;
    }
    return (void *)nullptr;
}

std::size_t ExtBufferAllocator::getAvailHdrSize() {
    if (firstHeaderPtr > preAllocatedBuffer) {
        return firstHeaderPtr - preAllocatedBuffer;
    }
    return 0;
}

void *ExtBufferAllocator::allocateBufferHeader(std::size_t length)
{
    if (getAvailHdrSize() >= length) {
        firstHeaderPtr -= length;
        NSLog(@"allocateBufferHeader() - [%p]->[%p:[[%p/%lu] -> [%ld] -> [%p/%lu]]",
              this,
              preAllocatedBuffer,
              firstHeaderPtr, length,
              frameBufferPtr - firstHeaderPtr,
              frameBufferPtr, frameBufferSize);
        return firstHeaderPtr;
    }
    return nullptr;
}

void ExtBufferAllocator::retrieveFullBufferPointer(void **bufferPtr, size_t *length) {
    *bufferPtr = firstHeaderPtr;
    *length = (frameBufferPtr - firstHeaderPtr) + frameBufferSize;
}




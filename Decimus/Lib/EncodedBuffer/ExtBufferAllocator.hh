// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

//
//  ExtBufferAllocator.hpp
//  Decimus
//
//  Created by Scott Henning on 8/7/23.
//
#ifndef ExtBufferAllocator_h
#define ExtBufferAllocator_h
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

//#include <cstddef>
//#include <cstdint>


class ExtBufferAllocator {
public:
    ExtBufferAllocator(std::size_t preAllocateSize, std::size_t preAllocateHdrSize);
    ~ExtBufferAllocator();
    void *allocateBuffer(std::size_t bufferSize);
    void *allocateBufferHeader(std::size_t length);
    void retrieveFullBufferPointer(void **bufferPtr, size_t *length);
    
    void resetBuffers();
    
    static void *_extendedAllocate(CFIndex allocSize, CFOptionFlags hint, void *info);
    static void _extendedDeallocate(void *ptr, void *info);
    
    
private:
    std::size_t getAvailHdrSize();

    std::size_t preAllocateSize;
    std::size_t preAllocateHdrSize;
    std::uint8_t *preAllocatedBuffer;
    
    std::uint8_t *frameBufferPtr;
    std::size_t frameBufferSize;
    
    std::uint8_t *firstHeaderPtr;
};

#endif /* ExtBufferAllocator_h */

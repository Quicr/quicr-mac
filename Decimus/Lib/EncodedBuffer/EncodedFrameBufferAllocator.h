//
//  EncodedFrameBufferAllocator.h
//  Decimus
//
//  Created by Scott Henning on 7/25/23.
//
#ifndef EncodedFrameBufferAllocator_h
#define EncodedFrameBufferAllocator_h
#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include "ExtBufferAllocator.h"
#endif

@interface BufferAllocator : NSObject {
    CFAllocatorContext context;
    CFAllocatorRef allocatorRef;
#ifdef __cplusplus
    ExtBufferAllocator *extBufferAllocatorPtr;
#endif
}
- (instancetype) init: (size_t) preAllocSize hdrSize: (size_t) preAllocHdrSize;
- (void) dealloc;
- (CFAllocatorRef)allocator;
- (void *) allocateBufferHeader: (size_t) length;
- (void) retrieveFullBufferPointer: (void **) fullBufferPtr len: (size_t *) length;
@end



#endif /* EncodedFrameBufferAllocator_h */



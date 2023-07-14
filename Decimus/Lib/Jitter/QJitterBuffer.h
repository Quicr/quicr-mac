#ifndef QJitterBuffer_h
#define QJitterBuffer_h

#import <Foundation/Foundation.h>

#include "Packet.h"
#ifdef __cplusplus
#include <memory>
#include "JitterBuffer.hh"
#endif

typedef void(*PacketCallback)(struct Packet[], size_t);


@interface QJitterBuffer : NSObject {
#ifdef __cplusplus
    std::unique_ptr<JitterBuffer> jitterBuffer;
#endif
}

-(instancetype) init: (size_t)elementSize
                        packet_elements:(size_t)packet_elements
                        clock_rate:(unsigned long)clock_rate
                        max_length_ms:(unsigned long)max_length_ms
                        min_length_ms:(unsigned long)min_length_ms;

-(size_t)enqueue:   (struct Packet)packet
                    concealment_callback:(PacketCallback)concealment_callback
                    free_callback:(PacketCallback)free_callback;

-(size_t)dequeue: (uint8_t*)destination
                    destination_length:(size_t)destination_length
                    elements:(size_t)elements;

@end

#endif

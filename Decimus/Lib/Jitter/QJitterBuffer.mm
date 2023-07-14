#import <Foundation/Foundation.h>
#import "QJitterBuffer.h"

#import <Foundation/Foundation.h>

#include <stdlib.h>

#include "Packet.h"
#include "JitterBuffer.hh"

@implementation QJitterBuffer
-(id)init: (size_t)elementSize
            packet_elements:(size_t)packet_elements
            clock_rate:(unsigned long)clock_rate
            max_length_ms:(unsigned long)max_length_ms
            min_length_ms:(unsigned long)min_length_ms
{
    self = [super init];
    if (self) jitterBuffer = std::make_unique<JitterBuffer>(elementSize,
                                                            packet_elements,
                                                            clock_rate,
                                                            std::chrono::milliseconds{max_length_ms},
                                                            std::chrono::milliseconds{min_length_ms});
    return self;
}

-(size_t)enqueue: (Packet)packet
                    concealment_callback:(PacketCallback)concealment_callback
                    free_callback:(PacketCallback)free_callback
{
    if (!jitterBuffer) return 0;

    return jitterBuffer->Enqueue({packet},
                                 [=](auto p) { return concealment_callback(p.data(), p.size()); },
                                 [=](auto p) { return free_callback(p.data(), p.size()); });
}

-(size_t)dequeue: (uint8_t*)destination
                    destination_length:(size_t)destination_length
                    elements:(size_t)elements
{
    if (!jitterBuffer) return 0;
    return jitterBuffer->Dequeue(destination, destination_length, elements);
}
@end

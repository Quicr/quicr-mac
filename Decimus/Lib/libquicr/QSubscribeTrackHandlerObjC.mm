#import <Foundation/Foundation.h>
#import "QSubscribeTrackHandlerObjC.h"
#import "QCommon.h"

@implementation QSubscribeTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (QFullTrackName) full_track_name
{
    moq::FullTrackName fullTrackName = ftnConvert(full_track_name);
    handlerPtr = std::make_shared<QSubscribeTrackHandler>(fullTrackName);
    return self;
}

-(QSubscribeTrackHandlerStatus) getStatus {
    assert(handlerPtr);
    auto status = handlerPtr->GetStatus();
    return static_cast<QSubscribeTrackHandlerStatus>(status);
}

-(void) setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

@end

// C++

QSubscribeTrackHandler::QSubscribeTrackHandler(const moq::FullTrackName& full_track_name): moq::SubscribeTrackHandler(full_track_name) { }

void QSubscribeTrackHandler::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QSubscribeTrackHandlerStatus>(status)];
    }
}

void QSubscribeTrackHandler::ObjectReceived(const moq::ObjectHeaders& object_headers,
                                            Span<uint8_t> data)
{
    if (_callbacks)
    {
        const std::uint8_t* priority = nullptr;
        if (object_headers.priority.has_value()) {
            priority = &*object_headers.priority;
        }
        const std::uint16_t* ttl = nullptr;
        if (object_headers.ttl.has_value()) {
            ttl = &*object_headers.ttl;
        }
        QObjectHeaders headers {
            .objectId = object_headers.object_id,
            .groupId = object_headers.group_id,
            .payloadLength = object_headers.payload_length,
            .priority = priority,
            .ttl = ttl
        };

        // Convert extensions.
        NSMutableDictionary<NSNumber*, NSData*>* extensions = [NSMutableDictionary dictionary];
        if (object_headers.extensions.has_value()) {
            for (const auto& kvp : *object_headers.extensions) {
                NSNumber* key = @(kvp.first);
                NSData* data = [NSData dataWithBytesNoCopy:(void*)kvp.second.data() length:kvp.second.size()];
                [extensions setObject:data forKey:key];
            }
        }
        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:data.data() length:data.size()];
        [_callbacks objectReceived:headers data:nsData extensions: extensions];
    }
}

void QSubscribeTrackHandler::PartialObjectReceived(const moq::ObjectHeaders& object_headers,
                                                   Span<uint8_t> data)
{
    if (_callbacks)
    {
        const std::uint8_t* priority = nullptr;
        if (object_headers.priority.has_value()) {
            priority = &*object_headers.priority;
        }
        const std::uint16_t* ttl = nullptr;
        if (object_headers.ttl.has_value()) {
            ttl = &*object_headers.ttl;
        }
        QObjectHeaders headers {
            .objectId = object_headers.object_id,
            .groupId = object_headers.group_id,
            .payloadLength = object_headers.payload_length,
            .priority = priority,
            .ttl = ttl
        };
        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:data.data() length:data.size()];
        // TODO: Populate extensions.
        NSDictionary<NSNumber*, NSData*>* extensions = @{};
        [_callbacks partialObjectReceived:headers data:nsData extensions:extensions];
    }
}

void QSubscribeTrackHandler::SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

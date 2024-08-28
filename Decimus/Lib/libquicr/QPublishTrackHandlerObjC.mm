#import <Foundation/Foundation.h>
#import "QPublishTrackHandlerObjC.h"
#import "QCommon.h"

@implementation QPublishTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (QFullTrackName) full_track_name trackMode: (QTrackMode) track_mode defaultPriority: (uint8_t) priority defaultTTL: (uint32_t) ttl
{
    moq::FullTrackName fullTrackName = ftnConvert(full_track_name);
    moq::TrackMode moqTrackMode = (moq::TrackMode)track_mode;
    
    // allocate handler...
    handlerPtr = std::make_shared<QPublishTrackHandler>(fullTrackName, moqTrackMode, priority, ttl);
    return self;
}


-(void) setCallbacks: (id<QPublishTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

moq::ObjectHeaders from(QObjectHeaders objectHeaders) {
    return moq::ObjectHeaders {
        .object_id = objectHeaders.objectId,
        .group_id = objectHeaders.groupId,
        .priority = objectHeaders.priority,
        .ttl = objectHeaders.ttl,
        .payload_length = objectHeaders.payloadLength
    };
}

-(QPublishObjectStatus)publishObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary * _Nonnull)extensions
{
    assert(handlerPtr);
    
    moq::Extensions cppExtensions;
    for (id key in extensions) {
        auto extensionKey = (NSUInteger)key;
        id value = extensions[key];
        auto* extensionValue = (NSData*)value;
        std::uint64_t cppKey = extensionKey;
        const auto* data = reinterpret_cast<const std::uint8_t*>(extensionValue.bytes);
        std::vector<std::uint8_t> cppValue(data, data + extensionValue.length);
        cppExtensions[cppKey] = cppValue;
    }
    auto headers = moq::ObjectHeaders {
        .object_id = objectHeaders.objectId,
        .group_id = objectHeaders.groupId,
        .priority = objectHeaders.priority,
        .ttl = objectHeaders.ttl,
        .payload_length = objectHeaders.payloadLength,
        .extensions = cppExtensions
    };
    auto* ptr = reinterpret_cast<const std::uint8_t*>([data bytes]);
    auto status = handlerPtr->PublishObject(headers, {ptr, data.length});
    return static_cast<QPublishObjectStatus>(status);
}

-(QPublishObjectStatus)publishPartialObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data {
    assert(handlerPtr);
    auto* ptr = reinterpret_cast<const std::uint8_t*>([data bytes]);
    auto headers = moq::ObjectHeaders {
        .object_id = objectHeaders.objectId,
        .group_id = objectHeaders.groupId,
        .priority = objectHeaders.priority,
        .ttl = objectHeaders.ttl,
        .payload_length = objectHeaders.payloadLength
    };
    auto status = handlerPtr->PublishPartialObject(headers, {ptr, data.length});
    return static_cast<QPublishObjectStatus>(status);
}

-(void) setDefaultPriority: (uint8_t) priority {
    assert(handlerPtr);
    handlerPtr->SetDefaultPriority(priority);
}

-(void) setDefaultTtl: (uint32_t) ttl {
    assert(handlerPtr);
    handlerPtr->SetDefaultTTL(ttl);
}

-(QPublishTrackHandlerStatus) getStatus {
    assert(handlerPtr);
    auto status = handlerPtr->GetStatus();
    return static_cast<QPublishTrackHandlerStatus>(status);
}

// C++

QPublishTrackHandler::QPublishTrackHandler(const moq::FullTrackName& full_track_name,
                                           moq::TrackMode track_mode,
                                           uint8_t default_priority,
                                           uint32_t default_ttl) : moq::PublishTrackHandler(full_track_name, track_mode, default_priority, default_ttl)
{
}

void QPublishTrackHandler::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QPublishTrackHandlerStatus>(status)];
    }
}

void QPublishTrackHandler::SetCallbacks(id<QPublishTrackHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

@end

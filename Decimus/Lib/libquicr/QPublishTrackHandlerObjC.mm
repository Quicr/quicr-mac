// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QPublishTrackHandlerObjC.h"
#import "QCommon.h"
#include <iostream>

@implementation QPublishTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (QFullTrackName) full_track_name trackMode: (QTrackMode) track_mode defaultPriority: (uint8_t) priority defaultTTL: (uint32_t) ttl
{
    moq::FullTrackName fullTrackName = ftnConvert(full_track_name);
    moq::TrackMode moqTrackMode = (moq::TrackMode)track_mode;
    handlerPtr = std::make_shared<QPublishTrackHandler>(fullTrackName, moqTrackMode, priority, ttl);
    return self;
}

-(void) setCallbacks: (id<QPublishTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

moq::ObjectHeaders from(QObjectHeaders objectHeaders, NSDictionary<NSNumber*, NSData*>* extensions) {
    std::optional<std::uint8_t> priority;
    if (objectHeaders.priority != nullptr) {
        priority = *objectHeaders.priority;
    } else {
        priority = std::nullopt;
    }

    std::optional<std::uint16_t> ttl;
    if (objectHeaders.ttl != nullptr) {
        ttl = *objectHeaders.ttl;
    } else {
        ttl = std::nullopt;
    }
    
    moq::Extensions moqExtensions;
    for (NSNumber* number in extensions) {
        NSData* value = extensions[number];
        const auto* ptr = reinterpret_cast<const std::uint8_t*>(value.bytes);
        moqExtensions[number.unsignedLongLongValue] = std::vector<std::uint8_t>(ptr, ptr + value.length);
    }

    return moq::ObjectHeaders {
        .object_id = objectHeaders.objectId,
        .group_id = objectHeaders.groupId,
        .priority = priority,
        .ttl = ttl,
        .payload_length = objectHeaders.payloadLength,
        .extensions = moqExtensions
    };
}

-(QPublishObjectStatus)publishObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*> * _Nonnull)extensions
{
    assert(handlerPtr);
    moq::ObjectHeaders headers = from(objectHeaders, extensions);
    auto* ptr = reinterpret_cast<const std::uint8_t*>([data bytes]);
    moq::BytesSpan span { ptr, data.length };
    auto status = handlerPtr->PublishObject(headers, span);
    return static_cast<QPublishObjectStatus>(status);
}

-(QPublishObjectStatus)publishPartialObject: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions:(NSDictionary<NSNumber *,NSData *> * _Nonnull) extensions {
    assert(handlerPtr);
    moq::ObjectHeaders headers = from(objectHeaders, extensions);
    auto* ptr = reinterpret_cast<const std::uint8_t*>([data bytes]);
    moq::BytesSpan span { ptr, data.length };
    // TODO: PublishPartialObject is not implemented in libquicr!
    abort();
    // auto status = handlerPtr->PublishPartialObject(headers, span);
    // return static_cast<QPublishObjectStatus>(status);
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

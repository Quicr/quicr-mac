// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QSubscribeTrackHandlerObjC.h"
#import "QFetchTrackHandlerObjC.h"
#import "QCommon.h"

@implementation QFetchTrackHandlerObjC : NSObject

-(id _Nonnull) initWithFullTrackName: (id<QFullTrackName> _Nonnull) full_track_name
                            priority: (uint8_t) priority
                          groupOrder: (QGroupOrder) groupOrder
                          startGroup: (uint64_t) startGroup
                            endGroup: (uint64_t) endGroup
                         startObject: (uint64_t) startObject
                           endObject: (uint64_t) endObject
{
    quicr::FullTrackName fullTrackName = ftnConvert(full_track_name);
    const auto order = static_cast<quicr::messages::GroupOrder>(groupOrder);
    handlerPtr = std::make_shared<QFetchTrackHandler>(fullTrackName,
                                                      priority,
                                                      order,
                                                      startGroup,
                                                      endGroup,
                                                      startObject,
                                                      endObject);
    return self;
}

-(QSubscribeTrackHandlerStatus) getStatus {
    assert(handlerPtr);
    auto status = handlerPtr->GetStatus();
    return static_cast<QSubscribeTrackHandlerStatus>(status);
}

-(id<QFullTrackName>) getFullTrackName {
    assert(handlerPtr);
    return ftnConvert(handlerPtr->GetFullTrackName());
}

-(uint8_t) getPriority {
    assert(handlerPtr);
    return handlerPtr->GetPriority();
}

-(QGroupOrder) getGroupOrder {
    assert(handlerPtr);
    return static_cast<QGroupOrder>(handlerPtr->GetGroupOrder());
}

-(QFilterType) getFilterType {
    assert(handlerPtr);
    return static_cast<QFilterType>(handlerPtr->GetFilterType());
}

-(void) setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

-(uint64_t) getStartGroup {
    assert(handlerPtr);
    return handlerPtr->GetStartGroup();
}

-(uint64_t) getEndGroup {
    assert(handlerPtr);
    return handlerPtr->GetEndGroup();
}

-(uint64_t) getStartObject {
    assert(handlerPtr);
    return handlerPtr->GetStartObject();
}

-(uint64_t) getEndObject {
    assert(handlerPtr);
    return handlerPtr->GetEndObject();
}
@end

// C++

QFetchTrackHandler::QFetchTrackHandler(const quicr::FullTrackName& full_track_name,
                                       quicr::messages::ObjectPriority priority,
                                       quicr::messages::GroupOrder group_order,
                                       quicr::messages::GroupId start_group,
                                       quicr::messages::GroupId end_group,
                                       quicr::messages::ObjectId start_object,
                                       quicr::messages::ObjectId end_object) : quicr::FetchTrackHandler(full_track_name,
                                                                                                        priority,
                                                                                                        group_order,
                                                                                                        start_group,
                                                                                                        end_group,
                                                                                                        start_object,
                                                                                                        end_object) {}

void QFetchTrackHandler::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QSubscribeTrackHandlerStatus>(status)];
    }
}

void QFetchTrackHandler::ObjectReceived(const quicr::ObjectHeaders& object_headers,
                                            quicr::BytesSpan data)
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
                NSData* data = [[NSData alloc] initWithBytesNoCopy:(void*)kvp.second.data()  length:kvp.second.size() deallocator:nil];
                [extensions setObject:data forKey:key];
            }
        }
        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:(void*)data.data() length:data.size() deallocator:nil];
        [_callbacks objectReceived:headers data:nsData extensions: extensions];
    }
}

void QFetchTrackHandler::PartialObjectReceived(const quicr::ObjectHeaders& object_headers,
                                                   quicr::BytesSpan data)
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
                NSData* data = [[NSData alloc] initWithBytesNoCopy:(void*)kvp.second.data()  length:kvp.second.size() deallocator:nil];
                [extensions setObject:data forKey:key];
            }
        }

        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:(void*)data.data() length:data.size() deallocator:nil];
        [_callbacks partialObjectReceived:headers data:nsData extensions:extensions];
    }
}

void QFetchTrackHandler::MetricsSampled(const quicr::SubscribeTrackMetrics &metrics)
{
    if (_callbacks) {
        const QSubscribeTrackMetrics converted = QSubscribeTrackHandler::Convert(metrics);
        [_callbacks metricsSampled: converted];
    }
}

void QFetchTrackHandler::SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

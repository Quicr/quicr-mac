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
    const quicr::messages::Location startLocation = {
        .group = startGroup,
        .object = startObject
    };
    const quicr::messages::FetchEndLocation endLocation = {
        .group = endGroup,
        .object = endObject
    };
    handlerPtr = std::make_shared<QFetchTrackHandler>(fullTrackName,
                                                      priority,
                                                      order,
                                                      startLocation,
                                                      endLocation);
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

-(id<QLocation> _Nonnull) getStartLocation {
    assert(handlerPtr);
    const auto& location = handlerPtr->GetStartLocation();
    return [[QLocationImpl alloc] initWithGroup:location.group object:location.object];
}

-(id<QLocation> _Nonnull) getEndLocation {
    assert(handlerPtr);
    const auto& location = handlerPtr->GetEndLocation();
    // FetchEndLocation has optional object - use 0 if not set
    uint64_t object = location.object.has_value() ? location.object.value() : 0;
    return [[QLocationImpl alloc] initWithGroup:location.group object:object];
}

-(void) setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

@end

// C++

QFetchTrackHandler::QFetchTrackHandler(const quicr::FullTrackName& full_track_name,
                                       quicr::messages::SubscriberPriority priority,
                                       quicr::messages::GroupOrder group_order,
                                       const quicr::messages::Location& start_location,
                                       const quicr::messages::FetchEndLocation& end_location) : quicr::FetchTrackHandler(full_track_name,
                                                                                                        priority,
                                                                                                        group_order,
                                                                                                        start_location,
                                                                                                        end_location) {}

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
            .groupId = object_headers.group_id,
            .subgroupId = object_headers.subgroup_id,
            .objectId = object_headers.object_id,
            .payloadLength = object_headers.payload_length,
            .status = static_cast<QObjectStatus>(object_headers.status),
            .priority = priority,
            .ttl = ttl,
        };

        // Convert extensions.
        const auto extensions = convertExtensions(object_headers.extensions);
        const auto immutableExtensions = convertExtensions(object_headers.immutable_extensions);

        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:(void*)data.data() length:data.size() deallocator:nil];
        [_callbacks objectReceived:headers data:nsData extensions: extensions immutableExtensions:immutableExtensions];
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
            .groupId = object_headers.group_id,
            .subgroupId = object_headers.subgroup_id,
            .objectId = object_headers.object_id,
            .payloadLength = object_headers.payload_length,
            .status = static_cast<QObjectStatus>(object_headers.status),
            .priority = priority,
            .ttl = ttl,
        };

        // Convert extensions.
        const auto extensions = convertExtensions(object_headers.extensions);
        const auto immutableExtensions = convertExtensions(object_headers.immutable_extensions);

        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:(void*)data.data() length:data.size() deallocator:nil];
        [_callbacks partialObjectReceived:headers data:nsData extensions:extensions immutableExtensions:immutableExtensions];
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

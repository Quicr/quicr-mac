// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QSubscribeTrackHandlerObjC.h"
#import "QCommon.h"

@implementation QSubscribeTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (id<QFullTrackName>) full_track_name priority:(uint8_t)priority groupOrder:(QGroupOrder)groupOrder filterType:(QFilterType)filterType publisherInitiated:(BOOL)publisherInitiated
{
    quicr::FullTrackName fullTrackName = ftnConvert(full_track_name);
    const auto order = static_cast<quicr::messages::GroupOrder>(groupOrder);
    const auto filter = static_cast<quicr::messages::FilterType>(filterType);
    handlerPtr = std::make_shared<QSubscribeTrackHandler>(fullTrackName, priority, order, filter, std::nullopt, publisherInitiated);
    return self;
}

-(QSubscribeTrackHandlerStatus) getStatus {
    assert(handlerPtr);
    auto status = handlerPtr->GetStatus();
    return static_cast<QSubscribeTrackHandlerStatus>(status);
}

-(void) setPriority: (uint8_t)priority {
    assert(handlerPtr);
    return handlerPtr->SetPriority(priority);
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

-(id<QLocation> _Nullable) getLatestLocation {
    assert(handlerPtr);
    const auto location = handlerPtr->GetLatestLocation();
    if (location.has_value()) {
        return [[QLocationImpl alloc] initWithGroup:location.value().group object:location.value().object];
    }
    return nullptr;
}

-(void) requestNewGroup {
    assert(handlerPtr);
    handlerPtr->RequestNewGroup();
}

-(void) setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

-(void) setDeliveryTimeout:(uint64_t)timeout
{
    assert(handlerPtr);
    handlerPtr->SetDeliveryTimeout(std::chrono::milliseconds(timeout));
}

-(void) pause
{
    assert(handlerPtr);
    handlerPtr->Pause();
}

-(void) resume
{
    assert(handlerPtr);
    handlerPtr->Resume();
}

-(void) setReceivedTrackAlias:(uint64_t)trackAlias
{
    assert(handlerPtr);
    handlerPtr->SetReceivedTrackAlias(trackAlias);
}

-(void) setRequestId:(uint64_t)requestId
{
    assert(handlerPtr);
    handlerPtr->SetRequestId(requestId);
}

@end

// C++

QSubscribeTrackHandler::QSubscribeTrackHandler(const quicr::FullTrackName& full_track_name,
                                               quicr::messages::ObjectPriority priority,
                                               quicr::messages::GroupOrder group_order,
                                               quicr::messages::FilterType filter_type,
                                               const std::optional<JoiningFetch>& joining_fetch,
                                               bool publisher_initiated): quicr::SubscribeTrackHandler(full_track_name,
                                                                                                       priority,
                                                                                                       group_order,
                                                                                                       filter_type,
                                                                                                       joining_fetch,
                                                                                                       publisher_initiated) {}

void QSubscribeTrackHandler::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QSubscribeTrackHandlerStatus>(status)];
    }
}

void QSubscribeTrackHandler::ObjectReceived(const quicr::ObjectHeaders& object_headers,
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
        auto extensions = convertExtensions(object_headers.extensions);
        auto immutable = convertExtensions(object_headers.immutable_extensions);
        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:(void*)data.data() length:data.size() deallocator:nil];
        [_callbacks objectReceived:headers data:nsData extensions: extensions immutableExtensions: immutable];
    }
}

void QSubscribeTrackHandler::PartialObjectReceived(const quicr::ObjectHeaders& object_headers,
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

        const auto extensions = convertExtensions(object_headers.extensions);
        const auto immutable = convertExtensions(object_headers.immutable_extensions);

        NSData* nsData = [[NSData alloc] initWithBytesNoCopy:(void*)data.data() length:data.size() deallocator:nil];
        [_callbacks partialObjectReceived:headers data:nsData extensions:extensions immutableExtensions:immutable];
    }
}

QSubscribeTrackMetrics QSubscribeTrackHandler::Convert(const quicr::SubscribeTrackMetrics& metrics)
{
    return QSubscribeTrackMetrics {
        .lastSampleTime = metrics.last_sample_time,
        .bytesReceived = metrics.bytes_received,
        .objectsReceived = metrics.objects_received
    };
}

void QSubscribeTrackHandler::MetricsSampled(const quicr::SubscribeTrackMetrics &metrics)
{
    if (_callbacks) {
        const QSubscribeTrackMetrics converted = Convert(metrics);
        [_callbacks metricsSampled: converted];
    }
}

void QSubscribeTrackHandler::SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

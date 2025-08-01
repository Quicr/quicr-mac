// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QSubscribeTrackHandlerObjC.h"
#import "QCommon.h"

@implementation QSubscribeTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (id<QFullTrackName>) full_track_name priority:(uint8_t)priority groupOrder:(QGroupOrder)groupOrder filterType:(QFilterType)filterType
{
    quicr::FullTrackName fullTrackName = ftnConvert(full_track_name);
    const auto order = static_cast<quicr::messages::GroupOrder>(groupOrder);
    const auto filter = static_cast<quicr::messages::FilterType>(filterType);
    handlerPtr = std::make_shared<QSubscribeTrackHandler>(fullTrackName, priority, order, filter);
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

@end

// C++

QSubscribeTrackHandler::QSubscribeTrackHandler(const quicr::FullTrackName& full_track_name,
                                               quicr::messages::ObjectPriority priority,
                                               quicr::messages::GroupOrder group_order,
                                               quicr::messages::FilterType filter_type): quicr::SubscribeTrackHandler(full_track_name,
                                                                                                                      priority,
                                                                                                                      group_order,
                                                                                                                      filter_type) {}

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

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QPublishTrackHandlerObjC.h"
#import "QCommon.h"
#include <iostream>

@implementation QPublishTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (id<QFullTrackName>) full_track_name trackMode: (QTrackMode) track_mode defaultPriority: (uint8_t) priority defaultTTL: (uint32_t) ttl
{
    quicr::FullTrackName fullTrackName = ftnConvert(full_track_name);
    quicr::TrackMode moqTrackMode = (quicr::TrackMode)track_mode;
    handlerPtr = std::make_shared<QPublishTrackHandler>(fullTrackName, moqTrackMode, priority, ttl);
    return self;
}

-(id<QFullTrackName>) getFullTrackName {
    assert(handlerPtr);
    return ftnConvert(handlerPtr->GetFullTrackName());
}

-(void) setCallbacks: (id<QPublishTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

std::optional<quicr::Extensions> from(NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable extensions) {
    std::optional<quicr::Extensions> moqExtensions;
    if (extensions == nil || extensions.count == 0) {
        moqExtensions = std::nullopt;
    } else {
        quicr::Extensions built;
        for (NSNumber* number in extensions) {
            NSArray<NSData*>* values = extensions[number];
            std::vector<std::vector<std::uint8_t>> dataValues;
            for (NSData* value in values) {
                const auto* ptr = reinterpret_cast<const std::uint8_t*>(value.bytes);
                dataValues.push_back(std::vector<std::uint8_t>(ptr, ptr + value.length));
            }
            built[number.unsignedLongLongValue] = dataValues;
        }
        // TODO: Move?
        moqExtensions = built;
    }
    return moqExtensions;
}

quicr::ObjectHeaders from(QObjectHeaders objectHeaders,
                          NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable extensions,
                          NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable immutable_extensions) {
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

    return quicr::ObjectHeaders {
        .object_id = objectHeaders.objectId,
        .group_id = objectHeaders.groupId,
        .priority = priority,
        .ttl = ttl,
        .payload_length = objectHeaders.payloadLength,
        .extensions = from(extensions),
        .immutable_extensions = from(immutable_extensions)
    };
}

-(QPublishObjectStatus)publishObject: (QObjectHeaders) objectHeaders
                                data: (NSData* _Nonnull) data
                          extensions: (NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) extensions
                 immutableExtensions: (NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) immutableExtensions
{
    assert(handlerPtr);
    quicr::ObjectHeaders headers = from(objectHeaders, extensions, immutableExtensions);
    auto* ptr = reinterpret_cast<const std::uint8_t*>([data bytes]);
    quicr::BytesSpan span { ptr, data.length };
    try {
        auto status = handlerPtr->PublishObject(headers, span);
        return static_cast<QPublishObjectStatus>(status);
    } catch (const std::exception& e) {
        std::cerr << "Exception in publishObject: " << e.what() << std::endl;
        return kQPublishObjectStatusInternalError;
    }
}

-(QPublishObjectStatus)publishPartialObject: (QObjectHeaders) objectHeaders
                                       data: (NSData* _Nonnull) data
                                 extensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) extensions
                        immutableExtensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable) immutableExtensions {
    assert(handlerPtr);
    quicr::ObjectHeaders headers = from(objectHeaders, extensions, immutableExtensions);
    auto* ptr = reinterpret_cast<const std::uint8_t*>([data bytes]);
    quicr::BytesSpan span { ptr, data.length };
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

-(void) setDefaultTrackMode: (QTrackMode)trackMode {
    assert(handlerPtr);
    handlerPtr->SetDefaultTrackMode((quicr::TrackMode)trackMode);
}

-(QPublishTrackHandlerStatus) getStatus {
    assert(handlerPtr);
    auto status = handlerPtr->GetStatus();
    return static_cast<QPublishTrackHandlerStatus>(status);
}

-(bool) canPublish {
    assert(handlerPtr);
    return handlerPtr->CanPublish();
}

-(QStreamHeaderType) getStreamMode {
    assert(handlerPtr);
    auto mode = handlerPtr->GetStreamMode();
    return static_cast<QStreamHeaderType>(mode);
}

-(void) setUseAnnounce: (bool) use {
    assert(handlerPtr);
    handlerPtr->SetUseAnnounce(use);
}

// C++

QPublishTrackHandler::QPublishTrackHandler(const quicr::FullTrackName& full_track_name,
                                           quicr::TrackMode track_mode,
                                           std::uint8_t default_priority,
                                           std::uint32_t default_ttl,
                                           std::optional<quicr::messages::StreamHeaderType> stream_mode) : quicr::PublishTrackHandler(full_track_name, track_mode, default_priority, default_ttl, stream_mode)
{
}

void QPublishTrackHandler::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QPublishTrackHandlerStatus>(status)];
    }
}

static QPublishTrackMetricsQuic convert(const quicr::PublishTrackMetrics::Quic& metrics)
{
    static_assert(sizeof(QPublishTrackMetricsQuic) == sizeof(quicr::PublishTrackMetrics::Quic));
    QPublishTrackMetricsQuic converted;
    memcpy(&converted, &metrics, sizeof(QPublishTrackMetricsQuic));
    return converted;
}

static QPublishTrackMetrics convert(const quicr::PublishTrackMetrics& metrics)
{
    return QPublishTrackMetrics {
        .lastSampleTime = metrics.last_sample_time,
        .bytesPublished = metrics.bytes_published,
        .objectsPublished = metrics.objects_published,
        .quic = convert(metrics.quic)
    };
}

void QPublishTrackHandler::MetricsSampled(const quicr::PublishTrackMetrics& metrics)
{
    if (_callbacks)
    {
        const QPublishTrackMetrics converted = convert(metrics);
        [_callbacks metricsSampled: converted];
    }
}

void QPublishTrackHandler::SetCallbacks(id<QPublishTrackHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

@end

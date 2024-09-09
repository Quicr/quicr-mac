// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clauses

#import <Foundation/Foundation.h>
#import "QClient.h"
#import "QClientObjC.h"
#include "TransportConfig.h"

#include <spdlog/sinks/callback_sink.h>

#include <memory>
#include <iostream>

static moq::TransportConfig convert(TransportConfig config) {
    moq::TransportConfig moq;
    moq.debug = config.debug;
    moq.idle_timeout_ms = config.idle_timeout_ms;
    moq.pacing_decrease_threshold_bps = config.pacing_decrease_threshold_Bps;
    moq.pacing_increase_threshold_bps = config.pacing_increase_threshold_Bps;
    moq.quic_cwin_minimum = config.quic_cwin_minimum;
    moq.quic_priority_limit = config.quic_priority_limit;
    moq.quic_qlog_path = config.quic_qlog_path ? std::string(config.quic_qlog_path) : "";
    moq.quic_wifi_shadow_rtt_us = config.quic_wifi_shadow_rtt_us;
    moq.time_queue_bucket_interval = config.time_queue_bucket_interval;
    moq.time_queue_init_queue_size = config.time_queue_init_queue_size;
    moq.time_queue_max_duration = config.time_queue_max_duration;
    moq.time_queue_rx_size = config.time_queue_rx_size;
    moq.tls_cert_filename = config.tls_cert_filename ? std::string(config.tls_cert_filename) : "";
    moq.tls_key_filename = config.tls_key_filename ? std::string(config.tls_key_filename)  : "";
    moq.use_bbr = config.use_bbr;
    moq.use_reset_wait_strategy = config.use_reset_wait_strategy;
    return moq;
}

@implementation QClientObjC : NSObject

-(id)initWithConfig: (QClientConfig) config logCallback:(LogCallback) logCallback
{
    moq::ClientConfig moqConfig;
    moqConfig.connect_uri = std::string(config.connectUri);
    moqConfig.endpoint_id = std::string(config.endpointId);
    moqConfig.metrics_sample_ms = config.metricsSampleMs;
    moqConfig.transport_config = convert(config.transportConfig);

    auto logger = spdlog::get("DECIMUS") ? spdlog::get("DECIMUS") : spdlog::callback_logger_mt("DECIMUS", [=](const spdlog::details::log_msg& msg) {
        NSString* m = [[NSString alloc] initWithBytesNoCopy: (void*)msg.payload.data() length: msg.payload.size() encoding: NSUTF8StringEncoding freeWhenDone: false];
        logCallback(static_cast<uint8_t>(msg.level), m, msg.level >= spdlog::level::err);
    });

    qClientPtr = std::make_unique<QClient>(moqConfig, std::move(logger));
    return self;
}

-(QClientStatus)connect
{
    assert(qClientPtr);
    auto status = qClientPtr->Connect();
    return static_cast<QClientStatus>(status);
}

-(QClientStatus) disconnect
{
    assert(qClientPtr);
    auto status = qClientPtr->Disconnect();
    return static_cast<QClientStatus>(status);
}

-(void)publishTrackWithHandler: (QPublishTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::PublishTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->PublishTrack(handler);
    }
}

-(void)unpublishTrackWithHandler: (QPublishTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::PublishTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->UnpublishTrack(handler);
    }
}

-(void)subscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::SubscribeTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->SubscribeTrack(handler);
    }
}

-(void)unsubscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::SubscribeTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->UnsubscribeTrack(handler);
    }
}

-(void) publishAnnounce: (NSData*) trackNamespace
{
    assert(qClientPtr);
    auto ptr = static_cast<const std::uint8_t*>(trackNamespace.bytes);
    moq::TrackNamespace name_space(ptr, ptr + trackNamespace.length);
    qClientPtr->PublishAnnounce(name_space);
}

-(void) publishUnannounce: (NSData*) trackNamespace
{
    assert(qClientPtr);
    auto ptr = static_cast<const std::uint8_t*>(trackNamespace.bytes);
    moq::TrackNamespace name_space(ptr, ptr + trackNamespace.length);
    qClientPtr->PublishUnannounce(name_space);
}

-(void)setCallbacks: (id<QClientCallbacks>) callbacks
{
    assert(qClientPtr);
    qClientPtr->SetCallbacks(callbacks);
}

-(QPublishAnnounceStatus) getAnnounceStatus: (NSData*) trackNamespace
{
    assert(qClientPtr);
    auto ptr = static_cast<const std::uint8_t*>(trackNamespace.bytes);
    moq::TrackNamespace name_space(ptr, ptr + trackNamespace.length);
    auto status = qClientPtr->GetAnnounceStatus(name_space);
    return static_cast<QPublishAnnounceStatus>(status);
}

// C++

QClient::QClient(moq::ClientConfig config, std::shared_ptr<spdlog::logger> logger)
    : moq::Client(config, std::move(logger))
{
}

QClient::~QClient()
{
}

void QClient::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QClientStatus>(status) ];
    }
}

void QClient::ServerSetupReceived(const moq::ServerSetupAttributes& server_setup_attributes) {
    // TODO: Implement.
}

void QClient::SetCallbacks(id<QClientCallbacks> callbacks)
{
    _callbacks = callbacks;
}

@end


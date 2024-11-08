// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clauses

#import <Foundation/Foundation.h>
#import "QClient.h"
#import "QClientObjC.h"
#include <memory>
#include <iostream>
#include "TransportConfig.h"

static quicr::TransportConfig convert(TransportConfig config) {
    quicr::TransportConfig moq;
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

-(id)initWithConfig: (QClientConfig) config
{
    quicr::ClientConfig moqConfig;
    moqConfig.connect_uri = std::string(config.connectUri);
    moqConfig.endpoint_id = std::string(config.endpointId);
    moqConfig.metrics_sample_ms = config.metricsSampleMs;
    moqConfig.transport_config = convert(config.transportConfig);
    qClientPtr = std::make_unique<QClient>(moqConfig);
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
        auto handler = std::static_pointer_cast<quicr::PublishTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->PublishTrack(handler);
    }
}

-(void)unpublishTrackWithHandler: (QPublishTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<quicr::PublishTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->UnpublishTrack(handler);
    }
}

-(void)subscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<quicr::SubscribeTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->SubscribeTrack(handler);
    }
}

-(void)unsubscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<quicr::SubscribeTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->UnsubscribeTrack(handler);
    }
}

-(void) publishAnnounce: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    qClientPtr->PublishAnnounce(nsConvert(trackNamespace));
}

-(void) publishUnannounce: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    qClientPtr->PublishUnannounce(nsConvert(trackNamespace));
}

-(void)setCallbacks: (id<QClientCallbacks>) callbacks
{
    assert(qClientPtr);
    qClientPtr->SetCallbacks(callbacks);
}

-(QPublishAnnounceStatus) getAnnounceStatus: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    auto status = qClientPtr->GetAnnounceStatus(nsConvert(trackNamespace));
    return static_cast<QPublishAnnounceStatus>(status);
}

// C++

QClient::QClient(quicr::ClientConfig config) : quicr::Client(config)
{
}

QClient::~QClient()
{
}

static QQuicConnectionMetrics convert(const quicr::QuicConnectionMetrics& metrics)
{
    static_assert(sizeof(quicr::QuicConnectionMetrics) == sizeof(QQuicConnectionMetrics));
    QQuicConnectionMetrics converted;
    memcpy(&converted, &metrics, sizeof(QQuicConnectionMetrics));
    return converted;
}

void QClient::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QClientStatus>(status) ];
    }
}

static QConnectionMetrics convert(const quicr::ConnectionMetrics& metrics)
{
    return QConnectionMetrics {
        .last_sample_time_us = metrics.last_sample_time,
        .quic = convert(metrics.quic)
    };
}

void QClient::MetricsSampled(const quicr::ConnectionMetrics& metrics)
{
    if (_callbacks)
    {
        const QConnectionMetrics converted = convert(metrics);
        [_callbacks metricsSampled: converted];
    }
}

static QServerSetupAttributes convert(const quicr::ServerSetupAttributes& server_setup_atttributes)
{
    QServerSetupAttributes attributes;
    attributes.moqt_version = server_setup_atttributes.moqt_version;
    attributes.server_id = server_setup_atttributes.server_id.c_str();
    return attributes;
}

void QClient::ServerSetupReceived(const quicr::ServerSetupAttributes& server_setup_attributes)
{
    if (_callbacks)
    {
        [_callbacks serverSetupReceived:convert(server_setup_attributes)];
    }
}

void QClient::SetCallbacks(id<QClientCallbacks> callbacks)
{
    _callbacks = callbacks;
}

@end


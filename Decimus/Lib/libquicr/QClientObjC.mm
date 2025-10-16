// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clauses

#import <Foundation/Foundation.h>
#import "QClient.h"
#import "QClientObjC.h"
#include <memory>
#include <iostream>
#include "TransportConfig.h"

static quicr::TransportConfig convert(TransportConfig config) {
    return {
        .debug = config.debug,
        .idle_timeout_ms = config.idle_timeout_ms,
        .quic_cwin_minimum = config.quic_cwin_minimum,
        .quic_priority_limit = config.quic_priority_limit,
        .quic_qlog_path = config.quic_qlog_path ? std::string(config.quic_qlog_path) : "",
        .quic_wifi_shadow_rtt_us = config.quic_wifi_shadow_rtt_us,
        .time_queue_bucket_interval = config.time_queue_bucket_interval,
        .time_queue_init_queue_size = config.time_queue_init_queue_size,
        .time_queue_max_duration = config.time_queue_max_duration,
        .time_queue_rx_size = config.time_queue_rx_size,
        .tls_cert_filename = config.tls_cert_filename ? std::string(config.tls_cert_filename) : "",
        .tls_key_filename = config.tls_key_filename ? std::string(config.tls_key_filename)  : "",
        .use_bbr = config.use_bbr,
        .use_reset_wait_strategy = config.use_reset_wait_strategy,
        .max_connections = config.max_connections,
        .ssl_keylog = config.ssl_keylog,
        .socket_buffer_size = config.socket_buffer_size
    };
}

@implementation QClientObjC : NSObject

-(id)initWithConfig: (QClientConfig) config
{
    quicr::ClientConfig moqConfig;
    moqConfig.connect_uri = std::string(config.connectUri);
    moqConfig.endpoint_id = std::string(config.endpointId);
    moqConfig.metrics_sample_ms = config.metricsSampleMs;
    moqConfig.transport_config = convert(config.transportConfig);
    qClientPtr = QClient::Create(moqConfig);
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

-(void)fetchTrackWithHandler:(QFetchTrackHandlerObjC *) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<quicr::FetchTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->FetchTrack(handler);
    }
}

-(void)cancelFetchTrackWithHandler:(QFetchTrackHandlerObjC *) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<quicr::FetchTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->CancelFetchTrack(handler);
    }
}

-(void) publishNamespace: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    qClientPtr->PublishNamespace(nsConvert(trackNamespace));
}

-(void) publishNamespaceDone: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    qClientPtr->PublishNamespaceDone(nsConvert(trackNamespace));
}

-(void)setCallbacks: (id<QClientCallbacks>) callbacks
{
    assert(qClientPtr);
    qClientPtr->SetCallbacks(callbacks);
}

-(QPublishNamespaceStatus) getPublishNamespaceStatus: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    auto status = qClientPtr->GetPublishNamespaceStatus(nsConvert(trackNamespace));
    return static_cast<QPublishNamespaceStatus>(status);
}

// C++

std::shared_ptr<QClient> QClient::Create(quicr::ClientConfig config) {
    return std::shared_ptr<QClient>(new QClient(config));
}

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


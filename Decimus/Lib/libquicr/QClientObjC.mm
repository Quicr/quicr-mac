// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clauses

#import <Foundation/Foundation.h>
#import "QClient.h"
#import "QClientObjC.h"
#include <memory>
#include <iostream>
#include <map>
#include "TransportConfig.h"
#include "quicr/handlers/subscribe_namespace_handler.h"

static quicr::TransportConfig convert(TransportConfig config) {
    return {
        .tls_cert_filename = config.tls_cert_filename ? std::string(config.tls_cert_filename) : "",
        .tls_key_filename = config.tls_key_filename ? std::string(config.tls_key_filename)  : "",
        .time_queue_init_queue_size = config.time_queue_init_queue_size,
        .time_queue_max_duration = config.time_queue_max_duration,
        .time_queue_bucket_interval = config.time_queue_bucket_interval,
        .time_queue_rx_size = config.time_queue_rx_size,
        .debug = config.debug,
        .quic_cwin_minimum = config.quic_cwin_minimum,
        .quic_wifi_shadow_rtt_us = config.quic_wifi_shadow_rtt_us,
        .idle_timeout_ms = config.idle_timeout_ms,
        .use_bbr = config.use_bbr,
        .quic_qlog_path = config.quic_qlog_path ? std::string(config.quic_qlog_path) : "",
        .quic_priority_limit = config.quic_priority_limit,
        .max_connections = config.max_connections,
        .ssl_keylog = config.ssl_keylog,
        .socket_buffer_size = config.socket_buffer_size
    };
}

[[maybe_unused]] static quicr::SubscribeAttributes convert(QSubscribeAttributes attributes) {
    quicr::SubscribeAttributes converted{};
    converted.priority = attributes.priority;
    converted.forward = attributes.forward;
    converted.delivery_timeout = std::chrono::milliseconds(attributes.deliveryTimeoutMs);
    converted.filter = std::monostate{};
    if (attributes.groupOrder != kQGroupOrderOriginalPublisherOrder) {
        converted.group_order = static_cast<quicr::messages::GroupOrder>(attributes.groupOrder);
    }
    converted.is_publisher_initiated = attributes.isPublisherInitiated;
    converted.new_group_request_id = attributes.newGroupRequestId;
    return converted;
}

static quicr::PublishOkAttributes convertOk(QPublishAttributes attributes) {
    return quicr::PublishOkAttributes {
        .subscriber_priority = attributes.priority,
        .group_order = attributes.groupOrder == kQGroupOrderOriginalPublisherOrder
            ? std::nullopt
            : std::make_optional(static_cast<quicr::messages::GroupOrder>(attributes.groupOrder)),
        .filter = std::monostate{},
        .forward = attributes.forward != 0,
        .subgroup_delivery_timeout = std::nullopt,
        .object_delivery_timeout = std::nullopt,
        .new_group_request_id = attributes.newGroupRequestId != 0 ? std::make_optional(attributes.newGroupRequestId) : std::nullopt,
    };
}

@implementation QClientObjC : NSObject

-(id)initWithConfig: (QClientConfig) config
{
    qClientConfig.connect_uri = std::string(config.connectUri);
    qClientConfig.endpoint_id = std::string(config.endpointId);
    qClientConfig.transport_config = convert(config.transportConfig);
    qClientConfig.transport_config.metrics_sample_ms = config.metricsSampleMs;
    qClientCallbacks = std::make_shared<QClient>();

    return self;
}

-(QClientStatus)connect
{
    assert(!qClientPtr);

    auto session = qSessionMgr.AddTransport(qClientConfig, qClientCallbacks);

    assert(session.lock());

    qClientPtr = session.lock();

    assert(qClientPtr);

    return static_cast<QClientStatus>(qClientPtr->GetStatus());
}

-(QClientStatus) disconnect
{
    assert(qClientPtr);
    qClientPtr->Disconnect();
    qClientPtr.reset();
    qClientCallbacks->CancelPendingPublishes();

    return kQClientStatusDisconnecting;
}

-(void)publishTrackWithHandler: (QPublishTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        qSessionMgr.AddHandler(qClientPtr, trackHandler->handlerPtr);
    }
}

-(void)unpublishTrackWithHandler: (QPublishTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        qSessionMgr.RemoveHandler(qClientPtr, trackHandler->handlerPtr);
    }
}

-(void)subscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        qSessionMgr.AddHandler(qClientPtr, trackHandler->handlerPtr);
    }
}

-(void)unsubscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        qSessionMgr.RemoveHandler(qClientPtr, trackHandler->handlerPtr);
    }
}

-(void)fetchTrackWithHandler:(QFetchTrackHandlerObjC *) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        qSessionMgr.AddHandler(qClientPtr, trackHandler->handlerPtr);
    }
}

-(void)cancelFetchTrackWithHandler:(QFetchTrackHandlerObjC *) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        qSessionMgr.RemoveHandler(qClientPtr, trackHandler->handlerPtr);
    }
}

-(void) publishNamespace: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    // TODO: Implement.
}

-(void) publishNamespaceDone: (QTrackNamespace) trackNamespace
{
    assert(qClientPtr);
    // TODO: Implement.
}

-(void)setCallbacks: (id<QClientCallbacks>) callbacks
{
    assert(qClientCallbacks);
    qClientCallbacks->SetCallbacks(callbacks);
}

-(void) subscribeNamespaceWithHandler: (QSubscribeNamespaceHandlerObjC*) handler
{
    assert(qClientPtr);
    assert(handler->handlerPtr);
    qSessionMgr.AddHandler(qClientPtr, handler->handlerPtr);
}

-(void) unsubscribeNamespaceWithHandler: (QSubscribeNamespaceHandlerObjC*) handler
{
    assert(qClientPtr);
    assert(handler->handlerPtr);
    qSessionMgr.RemoveHandler(qClientPtr, handler->handlerPtr);
}

-(void) resolvePublish: (uint64_t) connectionHandle
             requestId: (uint64_t) requestId
            attributes: (QPublishAttributes) attributes
                   tfn: (id<QFullTrackName> _Nonnull) tfn
              response: (QPublishResponse) response
               handler: (QSubscribeTrackHandlerObjC* _Nullable) handler {
    assert(qClientPtr);
    
    qClientCallbacks->ResolvePublish(requestId,
                                     convertOk(attributes),
                                     std::static_pointer_cast<quicr::SubscribeTrackHandler>(handler ? handler->handlerPtr : nullptr),
                                     response.ok);
}

// C++

static QMinMaxAvg convert(const quicr::MinMaxAvg& metrics)
{
    return QMinMaxAvg {
        .min = metrics.min,
        .max = metrics.max,
        .avg = metrics.avg,
        .value_sum = metrics.value_sum,
        .value_count = metrics.value_count,
    };
}

static QQuicConnectionMetrics convert(const quicr::QuicConnectionMetrics& metrics)
{
    return QQuicConnectionMetrics {
        .cwin_congested = metrics.cwin_congested,
        .prev_cwin_congested = metrics.prev_cwin_congested,
        .tx_congested = metrics.tx_congested,
        .tx_rate_bps = convert(metrics.tx_rate_bps),
        .rx_rate_bps = convert(metrics.rx_rate_bps),
        .tx_cwin_bytes = convert(metrics.tx_cwin_bytes),
        .tx_in_transit_bytes = convert(metrics.tx_in_transit_bytes),
        .rtt_us = convert(metrics.rtt_us),
        .srtt_us = convert(metrics.srtt_us),
        .tx_retransmits = metrics.tx_retransmits,
        .tx_lost_pkts = metrics.tx_lost_pkts,
        .tx_timer_losses = metrics.tx_timer_losses,
        .tx_spurious_losses = metrics.tx_spurious_losses,
        .rx_dgrams = metrics.rx_dgrams,
        .rx_dgrams_bytes = metrics.rx_dgrams_bytes,
        .tx_dgram_cb = metrics.tx_dgram_cb,
        .tx_dgram_ack = metrics.tx_dgram_ack,
        .tx_dgram_lost = metrics.tx_dgram_lost,
        .tx_dgram_spurious = metrics.tx_dgram_spurious,
    };
}

static QPublishAttributes convert(const quicr::PublishAttributes& attributes)
{
    QPublishAttributes converted{};
    converted.priority = attributes.default_publisher_priority;
    converted.forward = attributes.forward;
    converted.deliveryTimeoutMs = attributes.delivery_timeout.value_or(0);
    converted.groupOrder = static_cast<QGroupOrder>(attributes.default_publisher_group_order);
    converted.isPublisherInitiated = true;
    converted.newGroupRequestId = 0;
    converted.trackAlias = attributes.track_alias;
    converted.dynamicGroups = attributes.dynamic_groups;
    return converted;
}

void QClient::StatusChanged(const std::shared_ptr<quicr::Session>&, quicr::Session::Status status)
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

void QClient::MetricsSampled(const std::shared_ptr<quicr::Session>&, const quicr::ConnectionMetrics& metrics)
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

quicr::Reply<void, int> QClient::ServerSetupReceived(const std::shared_ptr<quicr::Session>&,
                                                      const quicr::ServerSetupAttributes& server_setup_attributes)
{
    if (_callbacks)
    {
        [_callbacks serverSetupReceived:convert(server_setup_attributes)];
    }
    return {};
}

void QClient::SetCallbacks(id<QClientCallbacks> callbacks)
{
    _callbacks = callbacks;
}

quicr::Reply<const quicr::PublishResponse, quicr::PublishErrorCode> QClient::PublishReceived(
  const std::shared_ptr<quicr::Session>&,
  const std::uint64_t request_id,
  const quicr::PublishAttributes& publish_attributes,
  std::weak_ptr<quicr::SubscribeNamespaceHandler> sub_ns_handler)
{
    if (!_callbacks) {
        return quicr::Unexpected<quicr::Error<quicr::PublishErrorCode>>(
          quicr::PublishErrorCode::kNotSupported, "Client callbacks are unavailable");
    }

    const auto promise = std::make_shared<std::promise<PublishReply>>();
    const auto future = std::make_shared<std::future<PublishReply>>(promise->get_future());
    {
        std::lock_guard lock(pending_publishes_mutex_);
        pending_publishes_.emplace(request_id, promise);
    }

    @autoreleasepool {
        auto locked = sub_ns_handler.lock();
        QSubscribeNamespaceHandlerObjC* objcHandler = nil;
        if (locked) {
            auto* qHandler = static_cast<QSubscribeNamespaceHandler*>(locked.get());
            objcHandler = qHandler->GetObjCWrapper();
        }
        [_callbacks publishReceived: 0
                          requestId:request_id
                                tfn:ftnConvert(publish_attributes.track_full_name)
                         attributes:convert(publish_attributes)
                       subNsHandler:objcHandler];
    }

    return quicr::Reply<const quicr::PublishResponse, quicr::PublishErrorCode>::Defer(
      [future] { return future->get(); });
}

void QClient::ResolvePublish(const uint64_t request_id,
                             const quicr::PublishOkAttributes& attributes,
                             std::shared_ptr<quicr::SubscribeTrackHandler> handler,
                             const bool accepted)
{
    std::shared_ptr<std::promise<PublishReply>> promise;
    {
        std::lock_guard lock(pending_publishes_mutex_);
        const auto it = pending_publishes_.find(request_id);
        if (it == pending_publishes_.end()) {
            return;
        }
        promise = std::move(it->second);
        pending_publishes_.erase(it);
    }

    if (accepted) {
        promise->set_value(quicr::PublishResponse { attributes, std::move(handler) });
    } else {
        promise->set_value(quicr::Unexpected<quicr::Error<quicr::PublishErrorCode>>(
          quicr::PublishErrorCode::kInternalError, "Publish rejected by application"));
    }
}

void QClient::CancelPendingPublishes()
{
    std::unordered_map<uint64_t, std::shared_ptr<std::promise<PublishReply>>> pending;
    {
        std::lock_guard lock(pending_publishes_mutex_);
        pending.swap(pending_publishes_);
    }
    for (const auto& [_, promise] : pending) {
        promise->set_value(quicr::Unexpected<quicr::Error<quicr::PublishErrorCode>>(
          quicr::PublishErrorCode::kInternalError, "Client disconnected"));
    }
}

@end

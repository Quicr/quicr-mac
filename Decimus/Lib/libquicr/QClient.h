// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QClient_h
#define QClient_h

#import "QClientCallbacks.h"

#include "quicr/session.h"
#include "quicr/config.h"

class QClient : public quicr::Session
{
public:
    static std::shared_ptr<QClient> Create(quicr::ClientConfig config,
                                           std::shared_ptr<quicr::Transport> transport,
                                           std::shared_ptr<quicr::Connection> connection,
                                           std::shared_ptr<timeq::tick_service> tick_service);
    virtual ~QClient();

    void StatusChanged(Status status) override;
    void ServerSetupReceived(const quicr::ServerSetupAttributes& serverSetupAttributes) override;
    void MetricsSampled(const quicr::ConnectionMetrics& metrics) override;
    void PublishReceived(unsigned long long,
                         const quicr::PublishAttributes&,
                         std::weak_ptr<quicr::SubscribeNamespaceHandler> sub_ns_handler) override;


    void SetCallbacks(id<QClientCallbacks> callbacks);
    id<QClientCallbacks> GetCallbacks() const { return _callbacks; }
private:
    QClient(quicr::ClientConfig config,
            std::shared_ptr<quicr::Transport> transport,
            std::shared_ptr<quicr::Connection> connection,
            std::shared_ptr<timeq::tick_service> tick_service);
    __weak id<QClientCallbacks> _callbacks;
};


#endif /* QClient_h */

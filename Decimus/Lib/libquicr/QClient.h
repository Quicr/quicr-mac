// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QClient_h
#define QClient_h

#import "QClientCallbacks.h"

#include "quicr/client.h"
#include "quicr/config.h"

class QClient : public quicr::Client
{
public:
    static std::shared_ptr<QClient> Create(quicr::ClientConfig config);
    ~QClient();

    void StatusChanged(Status status) override;
    void ServerSetupReceived(const quicr::ServerSetupAttributes& serverSetupAttributes) override;
    void MetricsSampled(const quicr::ConnectionMetrics& metrics) override;
    void PublishReceived(unsigned long long,
                         unsigned long long,
                         const quicr::messages::PublishAttributes&) override;


    void SetCallbacks(id<QClientCallbacks> callbacks);
    id<QClientCallbacks> GetCallbacks() const { return _callbacks; }
private:
    QClient(quicr::ClientConfig config);
    __weak id<QClientCallbacks> _callbacks;
};


#endif /* QClient_h */

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QClient_h
#define QClient_h

#import "QClientCallbacks.h"

#include "moq/client.h"
#include "moq/config.h"

class QClient : public moq::Client
{
public:
    QClient(moq::ClientConfig config, std::shared_ptr<spdlog::logger> logger);
    ~QClient();

    void StatusChanged(Status status) override;
    void ServerSetupReceived(const moq::ServerSetupAttributes& serverSetupAttributes) override;
    
    void SetCallbacks(id<QClientCallbacks> callbacks);
private:
    __weak id<QClientCallbacks> _callbacks;
};


#endif /* QClient_h */

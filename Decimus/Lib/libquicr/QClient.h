// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QClient_h
#define QClient_h

#import "QClientCallbacks.h"

#include "quicr/session_callbacks.h"
#include "quicr/config.h"

#include <future>
#include <mutex>
#include <unordered_map>

class QClient final : public quicr::Session::ClientCallbacks
{
public:
    void StatusChanged(const std::shared_ptr<quicr::Session>& session, quicr::Session::Status status) override;
    quicr::Reply<void, int> ServerSetupReceived(const std::shared_ptr<quicr::Session>& session,
                                                 const quicr::ServerSetupAttributes& serverSetupAttributes) override;
    void MetricsSampled(const std::shared_ptr<quicr::Session>& session,
                        const quicr::ConnectionMetrics& metrics) override;
    quicr::Reply<const quicr::PublishResponse, quicr::PublishErrorCode> PublishReceived(
        const std::shared_ptr<quicr::Session>& session,
        unsigned long long request_id,
        const quicr::PublishAttributes& attributes,
        std::weak_ptr<quicr::SubscribeNamespaceHandler> sub_ns_handler) override;


    void SetCallbacks(id<QClientCallbacks> callbacks);
    id<QClientCallbacks> GetCallbacks() const { return _callbacks; }
    void ResolvePublish(uint64_t request_id,
                        const quicr::PublishOkAttributes& attributes,
                        std::shared_ptr<quicr::SubscribeTrackHandler> handler,
                        bool accepted);
    void CancelPendingPublishes();

private:
    using PublishReply = quicr::Expected<const quicr::PublishResponse, quicr::Error<quicr::PublishErrorCode>>;

    __weak id<QClientCallbacks> _callbacks;
    std::mutex pending_publishes_mutex_;
    std::unordered_map<uint64_t, std::shared_ptr<std::promise<PublishReply>>> pending_publishes_;
};


#endif /* QClient_h */

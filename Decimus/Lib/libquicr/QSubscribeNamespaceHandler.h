// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeNamespaceHandler_h
#define QSubscribeNamespaceHandler_h

#include "quicr/subscribe_namespace_handler.h"
#include "quicr/detail/attributes.h"
#import "QSubscribeNamespaceHandlerCallbacks.h"

class QSubscribeNamespaceHandler : public quicr::SubscribeNamespaceHandler
{
public:
    explicit QSubscribeNamespaceHandler(const quicr::TrackNamespace& prefix,
                                        const std::optional<quicr::messages::Filter>& filter = std::nullopt);

    void StatusChanged(Status status) override;
    std::shared_ptr<quicr::SubscribeTrackHandler> NewTrackReceived(const quicr::messages::PublishAttributes& attributes) const override;

    void SetCallbacks(id<QSubscribeNamespaceHandlerCallbacks> callbacks);

private:
    __weak id<QSubscribeNamespaceHandlerCallbacks> _callbacks;
};

#endif /* QSubscribeNamespaceHandler_h */

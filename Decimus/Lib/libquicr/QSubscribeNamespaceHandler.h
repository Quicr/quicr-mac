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
                                        const std::optional<quicr::messages::TrackFilter>& track_filter = std::nullopt);

    void StatusChanged(Status status) override;
    bool IsTrackAcceptable(const quicr::FullTrackName& name) const override;
    std::shared_ptr<quicr::SubscribeTrackHandler> CreateHandler(const quicr::messages::PublishAttributes& attributes) override;

    void SetCallbacks(id<QSubscribeNamespaceHandlerCallbacks> callbacks);

    std::optional<quicr::messages::TrackFilter> GetTrackFilter() const { return track_filter_; }

private:
    __weak id<QSubscribeNamespaceHandlerCallbacks> _callbacks;
    std::optional<quicr::messages::TrackFilter> track_filter_;
};

#endif /* QSubscribeNamespaceHandler_h */

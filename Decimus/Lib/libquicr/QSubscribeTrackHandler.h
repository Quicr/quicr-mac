// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeTrackHandler_h
#define QSubscribeTrackHandler_h

#include "quicr/subscribe_track_handler.h"
#include "quicr/track_name.h"
#import "QSubscribeTrackHandlerCallbacks.h"

class QSubscribeTrackHandler : public quicr::SubscribeTrackHandler
{
public:
    QSubscribeTrackHandler(const quicr::FullTrackName& full_track_name,
                           quicr::messages::ObjectPriority priority,
                           quicr::messages::GroupOrder group_order,
                           quicr::messages::FilterType filter_type,
                           const std::optional<JoiningFetch>& joining_fetch = std::nullopt,
                           bool publisher_initiated = false);

    // Callbacks.
    void StatusChanged(Status status) override;
    void ObjectReceived(const quicr::ObjectHeaders& object_headers, quicr::BytesSpan data) override;
    void PartialObjectReceived(const quicr::ObjectHeaders& object_headers, quicr::BytesSpan data) override;
    void MetricsSampled(const quicr::SubscribeTrackMetrics& metrics) override;

    // Methods.
    void SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks);
    static QSubscribeTrackMetrics Convert(const quicr::SubscribeTrackMetrics& metrics);

private:
    __weak id<QSubscribeTrackHandlerCallbacks> _callbacks;
};

#endif /* QSubscribeTrackHandler_h */

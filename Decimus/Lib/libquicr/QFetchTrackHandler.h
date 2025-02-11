// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QFetchTrackHandler_h
#define QFetchTrackHandler_h

#include "quicr/fetch_track_handler.h"
#include "quicr/track_name.h"
#import "QSubscribeTrackHandlerCallbacks.h"

class QFetchTrackHandler : public quicr::FetchTrackHandler
{
public:
    QFetchTrackHandler(const quicr::FullTrackName& full_track_name,
                       quicr::messages::ObjectPriority priority,
                       quicr::messages::GroupOrder group_order,
                       quicr::messages::GroupId start_group,
                       quicr::messages::GroupId end_group,
                       quicr::messages::ObjectId start_object,
                       quicr::messages::ObjectId end_object);

    // Callbacks.
    void StatusChanged(Status status) override;
    void ObjectReceived(const quicr::ObjectHeaders& object_headers, quicr::BytesSpan data) override;
    void PartialObjectReceived(const quicr::ObjectHeaders& object_headers, quicr::BytesSpan data) override;
    void MetricsSampled(const quicr::SubscribeTrackMetrics& metrics) override;

    // Methods.
    void SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks);


private:
    __weak id<QSubscribeTrackHandlerCallbacks> _callbacks;
};

#endif /* QSubscribeTrackHandler_h */

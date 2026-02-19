// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QPublishTrackHandler_h
#define QPublishTrackHandler_h

#include "quicr/publish_track_handler.h"
#include "quicr/track_name.h"

#import "QPublishTrackHandlerCallbacks.h"

class QPublishTrackHandler : public quicr::PublishTrackHandler
{
public:
    QPublishTrackHandler(const quicr::FullTrackName& full_track_name,
                         quicr::TrackMode track_mode,
                         std::uint8_t default_priority,
                         std::uint32_t default_ttl,
                         std::optional<quicr::messages::StreamHeaderProperties> stream_mode = std::nullopt);

    void StatusChanged(Status status) override;
    void MetricsSampled(const quicr::PublishTrackMetrics&) override;

    void SetCallbacks(id<QPublishTrackHandlerCallbacks> callbacks);

private:
    __weak id<QPublishTrackHandlerCallbacks> _callbacks;
};


#endif /* QPublishTrackHandler_h */

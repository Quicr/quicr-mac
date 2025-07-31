// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QCommon.h"

typedef NS_ENUM(uint8_t, QPublishTrackHandlerStatus) {
    kQPublishTrackHandlerStatusOk,
    kQPublishTrackHandlerStatusNotConnected,
    kQPublishTrackHandlerStatusNotAnnounced,
    kQPublishTrackHandlerStatusPendingAnnounceResponse,
    kQPublishTrackHandlerStatusAnnounceNotAuthorized,
    kQPublishTrackHandlerStatusNoSubscribers,
    kQPublishTrackHandlerStatusSendingUnannounce,
    kQPublishTrackHandlerStatusSubscriptionUpdated,
    kQPublishTrackHandlerStatusNewGroupRequested,
    kQPublishTrackHandlerStatusPendingPublishOk,
    kQPublishTrackHandlerStatusPaused,
};

typedef struct QPublishTrackMetricsQuic {
    uint64_t tx_buffer_drops;
    uint64_t tx_queue_discards;
    uint64_t tx_queue_expired;
    uint64_t tx_delayed_callback;
    uint64_t tx_reset_wait;
    QMinMaxAvg tx_queue_size;
    QMinMaxAvg tx_callback_ms;
    QMinMaxAvg tx_object_duration_us;
} QPublishTrackMetricsQuic;

typedef struct QPublishTrackMetrics {
    uint64_t lastSampleTime;
    uint64_t bytesPublished;
    uint64_t objectsPublished;
    QPublishTrackMetricsQuic quic;
} QPublishTrackMetrics;

@protocol QPublishTrackHandlerCallbacks
- (void) statusChanged: (QPublishTrackHandlerStatus) status;
- (void) metricsSampled: (QPublishTrackMetrics) metrics;
@end

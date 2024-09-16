// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QCommon.h"

typedef NS_ENUM(uint8_t, QSubscribeTrackHandlerStatus) {
    kQSubscribeTrackHandlerStatusOk,
    kQSubscribeTrackHandlerStatusNotConnected,
    kQSubscribeTrackHandlerStatusSubscribeError,
    kQSubscribeTrackHandlerStatusNotAuthorized,
    kQSubscribeTrackHandlerStatusNotSubscribed,
    kQSubscribeTrackHandlerStatusPendingSubscribeResponse,
    kQSubscribeTrackHandlerStatusSendingUnsubscribe
};

typedef struct QSubscribeTrackMetrics {
    uint64_t lastSampleTime;
    uint64_t bytesPublished;
    uint64_t objectsPublished;
} QSubscribeTrackMetrics;

@protocol QSubscribeTrackHandlerCallbacks
- (void) statusChanged: (QSubscribeTrackHandlerStatus) status;
- (void) objectReceived: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) extensions;
- (void) partialObjectReceived: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) extensions;
- (void) metricsSampled: (QSubscribeTrackMetrics) metrics;
@end

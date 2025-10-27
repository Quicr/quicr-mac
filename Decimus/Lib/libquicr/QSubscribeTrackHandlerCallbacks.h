// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QCommon.h"

typedef NS_ENUM(uint8_t, QSubscribeTrackHandlerStatus) {
    kQSubscribeTrackHandlerStatusOk,
    kQSubscribeTrackHandlerStatusNotConnected,
    kQSubscribeTrackHandlerStatusError,
    kQSubscribeTrackHandlerStatusNotAuthorized,
    kQSubscribeTrackHandlerStatusNotSubscribed,
    kQSubscribeTrackHandlerStatusPendingResponse,
    kQSubscribeTrackHandlerStatusSendingUnsubscribe,
    kQSubscribeTrackHandlerStatusPaused,
    kQSubscribeTrackHandlerStatusNewGroupRequested,
    kQSubscribeTrackHandlerStatusCancelled,
    kQSubscribeTrackHandlerStatusDoneByFin,
    kQSubscribeTrackHandlerStatusDoneByReset,
};

typedef struct QSubscribeTrackMetrics {
    uint64_t lastSampleTime;
    uint64_t bytesReceived;
    uint64_t objectsReceived;
} QSubscribeTrackMetrics;

@protocol QSubscribeTrackHandlerCallbacks
- (void) statusChanged: (QSubscribeTrackHandlerStatus) status;
- (void) objectReceived: (QObjectHeaders) objectHeaders
                   data: (NSData* _Nonnull) data
             extensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) extensions
    immutableExtensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) immutableExtensions;
- (void) partialObjectReceived: (QObjectHeaders) objectHeaders
                          data: (NSData* _Nonnull) data
                    extensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) extensions
           immutableExtensions: (NSDictionary<NSNumber*, NSData*>* _Nullable) immutableExtensions;
- (void) metricsSampled: (QSubscribeTrackMetrics) metrics;
@end

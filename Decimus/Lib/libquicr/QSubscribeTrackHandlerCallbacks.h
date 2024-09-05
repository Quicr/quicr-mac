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

@protocol QSubscribeTrackHandlerCallbacks
- (void) statusChanged: (QSubscribeTrackHandlerStatus) status;
- (void) objectReceived: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nonnull) extensions;
- (void) partialObjectReceived: (QObjectHeaders) objectHeaders data: (NSData* _Nonnull) data extensions: (NSDictionary<NSNumber*, NSData*>* _Nonnull) extensions;
@end

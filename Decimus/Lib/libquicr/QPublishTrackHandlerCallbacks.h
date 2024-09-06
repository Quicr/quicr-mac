// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

typedef NS_ENUM(uint8_t, QPublishTrackHandlerStatus) {
    kQPublishTrackHandlerStatusOk,
    kQPublishTrackHandlerStatusNotConnected,
    kQPublishTrackHandlerStatusNotAnnounced,
    kQPublishTrackHandlerStatusPendingAnnounceResponse,
    kQPublishTrackHandlerStatusAnnounceNotAuthorized,
    kQPublishTrackHandlerStatusNoSubscribers,
    kQPublishTrackHandlerStatusSendingUnannounce
};

@protocol QPublishTrackHandlerCallbacks
- (void) statusChanged: (QPublishTrackHandlerStatus) status;
@end

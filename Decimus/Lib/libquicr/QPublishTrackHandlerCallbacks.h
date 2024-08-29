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

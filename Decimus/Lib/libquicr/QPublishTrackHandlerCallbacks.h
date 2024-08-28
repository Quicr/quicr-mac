typedef NS_ENUM(uint8_t, QPublishTrackHandlerStatus) {
    kQPublishTrackHandlerStatusOK = 0,
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

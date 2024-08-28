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
- (void) objectReceived: (QObjectHeaders) objectHeaders data: (uint8_t *) data length: (size_t) length;
- (void) partialObjectReceived: (QObjectHeaders) objectHeaders data: (uint8_t *) data length: (size_t) length;
@end

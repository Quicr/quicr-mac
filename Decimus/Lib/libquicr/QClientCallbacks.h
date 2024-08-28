#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, QClientStatus) {
    kReady,
    kNotReady,
    kInternalError,
    kInvalidParams,
    kClientConnecting,
    kDisconnecting,
    kClientNotConnected,
    kClientFailedToConnect
};

typedef NS_ENUM(uint8_t, QPublishAnnounceStatus) {
    kOK,
    kNotConnected,
    kNotAnnounced,
    kPendingAnnounceResponse,
    kAnnounceNotAuthorized,
    kSendingUnannounce
};

typedef struct QServerSetupAttributes {
    uint64_t moqt_version;
    const char* server_id;
} QServerSetupAttributes;

@protocol QClientCallbacks
- (void) statusChanged: (QClientStatus) status;
- (void) serverSetupReceived: (QServerSetupAttributes) serverSetupAttributes;
- (void) announceStatusChanged: (NSData*) track_namespace status: (QPublishAnnounceStatus) status;
@end

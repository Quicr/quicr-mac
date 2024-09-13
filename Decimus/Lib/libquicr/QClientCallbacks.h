// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, QClientStatus) {
    kQClientStatusReady,
    kQClientStatusNotReady,
    kQClientStatusInternalError,
    kQClientStatusInvalidParams,
    kQClientStatusClientConnecting,
    kQClientStatusDisconnecting,
    kQClientStatusClientNotConnected,
    kQClientStatusClientFailedToConnect,
    kQClientStatusClientPendigServerSetup
};

typedef NS_ENUM(uint8_t, QPublishAnnounceStatus) {
    kQPublishAnnounceStatusOK,
    kQPublishAnnounceStatusNotConnected,
    kQPublishAnnounceStatusNotAnnounced,
    kQPublishAnnounceStatusPendingAnnounceResponse,
    kQPublishAnnounceStatusAnnounceNotAuthorized,
    kQPublishAnnounceStatusSendingUnannounce
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

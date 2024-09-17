// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QCommon.h"

typedef NS_ENUM(uint8_t, QClientStatus) {
    kQClientStatusReady,
    kQClientStatusNotReady,
    kQClientStatusInternalError,
    kQClientStatusInvalidParams,
    kQClientStatusClientConnecting,
    kQClientStatusDisconnecting,
    kQClientStatusClientNotConnected,
    kQClientStatusClientFailedToConnect,
    kQClientStatusClientPendingServerSetup
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

typedef struct QQuicConnectionMetrics {
    uint64_t cwin_congested;
    uint64_t prev_cwin_congested;
    uint64_t tx_congested;
    QMinMaxAvg tx_rate_bps;
    QMinMaxAvg rx_rate_bps;
    QMinMaxAvg tx_cwin_bytes;
    QMinMaxAvg tx_in_transit_bytes;
    QMinMaxAvg rtt_us;
    QMinMaxAvg srtt_us;
    uint64_t tx_retransmits;
    uint64_t tx_lost_pkts;
    uint64_t tx_timer_losses;
    uint64_t tx_spurious_losses;
    uint64_t rx_dgrams;
    uint64_t rx_dgrams_bytes;
    uint64_t tx_dgram_cb;
    uint64_t tx_dgram_ack;
    uint64_t tx_dgram_lost;
    uint64_t tx_dgram_spurious;
    uint64_t tx_dgram_drops;
} QQuicConnectionMetrics;

typedef struct QConnectionMetrics {
    uint64_t last_sample_time_us;
    QQuicConnectionMetrics quic;
} QConnectionMetrics;

@protocol QClientCallbacks
- (void) statusChanged: (QClientStatus) status;
- (void) serverSetupReceived: (QServerSetupAttributes) serverSetupAttributes;
- (void) announceStatusChanged: (NSData*) track_namespace status: (QPublishAnnounceStatus) status;
- (void) metricsSampled: (QConnectionMetrics) metrics;
@end

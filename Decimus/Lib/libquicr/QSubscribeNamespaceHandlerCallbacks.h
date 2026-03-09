// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeNamespaceHandlerCallbacks_h
#define QSubscribeNamespaceHandlerCallbacks_h

#import <Foundation/Foundation.h>
#import "QFullTrackName.h"
#import "QCommon.h"

typedef struct QPublishAttributes {
    uint8_t priority;
    QGroupOrder groupOrder;
    uint64_t deliveryTimeoutMs;
    uint64_t expiresMs;
    QFilterType filterType;
    uint8_t forward;
    uint64_t newGroupRequestId;
    bool isPublisherInitiated;
    uint64_t startGroupId;
    uint64_t startObjectId;
    uint64_t trackAlias;
    bool dynamicGroups;
} QPublishAttributes;

typedef NS_ENUM(uint8_t, QSubscribeNamespaceErrorCode) {
    kQSubscribeNamespaceErrorCodeOK,
};

typedef NS_ENUM(uint8_t, QSubscribeNamespaceHandlerStatus) {
    kQSubscribeNamespaceHandlerStatusOk,
    kQSubscribeNamespaceHandlerStatusNotSubscribed,
    kQSubscribeNamespaceHandlerStatusError,
};

@protocol QSubscribeNamespaceHandlerCallbacks
- (void)statusChanged:(QSubscribeNamespaceHandlerStatus)status
            errorCode:(QSubscribeNamespaceErrorCode)errorCode;
@end

#endif /* QSubscribeNamespaceHandlerCallbacks_h */

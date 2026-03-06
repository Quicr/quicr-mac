// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeNamespaceHandlerCallbacks_h
#define QSubscribeNamespaceHandlerCallbacks_h

#import <Foundation/Foundation.h>
#import "QClientCallbacks.h"
#import "QFullTrackName.h"
#import "QCommon.h"

@class QSubscribeTrackHandlerObjC;

typedef NS_ENUM(uint8_t, QSubscribeNamespaceHandlerStatus) {
    kQSubscribeNamespaceHandlerStatusOk,
    kQSubscribeNamespaceHandlerStatusNotSubscribed,
    kQSubscribeNamespaceHandlerStatusError,
};

@protocol QSubscribeNamespaceHandlerCallbacks
- (void)statusChanged:(QSubscribeNamespaceHandlerStatus)status
            errorCode:(QSubscribeNamespaceErrorCode)errorCode;
- (QSubscribeTrackHandlerObjC* _Nullable) newTrackReceived:(id<QFullTrackName> _Nonnull) fullTrackName
                                                attributes:(QPublishAttributes)attributes;
@end

#endif /* QSubscribeNamespaceHandlerCallbacks_h */

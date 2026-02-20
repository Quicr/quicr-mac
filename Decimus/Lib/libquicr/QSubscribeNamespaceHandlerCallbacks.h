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
- (bool)isTrackAcceptable:(id<QFullTrackName> _Nonnull)fullTrackName;
- (QSubscribeTrackHandlerObjC* _Nullable)createHandler:(id<QFullTrackName> _Nonnull)fullTrackName
                                            trackAlias:(uint64_t)trackAlias
                                              priority:(uint8_t)priority
                                            groupOrder:(QGroupOrder)groupOrder
                                            filterType:(QFilterType)filterType;
@end

#endif /* QSubscribeNamespaceHandlerCallbacks_h */

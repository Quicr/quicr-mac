// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeNamespaceHandlerCallbacks_h
#define QSubscribeNamespaceHandlerCallbacks_h

#import <Foundation/Foundation.h>
#import "QClientCallbacks.h"

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

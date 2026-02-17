// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeNamespaceHandlerObjC_h
#define QSubscribeNamespaceHandlerObjC_h

#ifdef __cplusplus
#include "QSubscribeNamespaceHandler.h"
#include <memory>
#endif

#import <Foundation/Foundation.h>
#import "QFullTrackName.h"
#import "QSubscribeNamespaceHandlerCallbacks.h"

@interface QSubscribeNamespaceHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QSubscribeNamespaceHandler> handlerPtr;
#endif
}

- (id _Nonnull)initWithNamespacePrefix:(QTrackNamespace _Nonnull)namespacePrefix;
- (QTrackNamespace _Nonnull)getNamespacePrefix;
- (QSubscribeNamespaceHandlerStatus)getStatus;
- (void)setCallbacks:(id<QSubscribeNamespaceHandlerCallbacks> _Nonnull)callbacks;
@end

#endif /* QSubscribeNamespaceHandlerObjC_h */

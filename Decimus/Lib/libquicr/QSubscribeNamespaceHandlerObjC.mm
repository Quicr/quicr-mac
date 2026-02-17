// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QSubscribeNamespaceHandlerObjC.h"

QSubscribeNamespaceHandler::QSubscribeNamespaceHandler(const quicr::TrackNamespace& prefix)
  : quicr::SubscribeNamespaceHandler(prefix)
{
}

void QSubscribeNamespaceHandler::StatusChanged(Status status)
{
    if (_callbacks) {
        QSubscribeNamespaceErrorCode errorCode = QSubscribeNamespaceErrorCode::kQSubscribeNamespaceErrorCodeOK;
        if (status == Status::kError) {
            auto error = GetError();
            if (error.has_value()) {
                errorCode = static_cast<QSubscribeNamespaceErrorCode>(error->first);
            }
        }
        [_callbacks statusChanged:static_cast<QSubscribeNamespaceHandlerStatus>(status) errorCode:errorCode];
    }
    quicr::SubscribeNamespaceHandler::StatusChanged(status);
}

void QSubscribeNamespaceHandler::SetCallbacks(id<QSubscribeNamespaceHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

@implementation QSubscribeNamespaceHandlerObjC : NSObject

-(id)initWithNamespacePrefix:(QTrackNamespace)namespacePrefix
{
    handlerPtr = std::make_shared<QSubscribeNamespaceHandler>(nsConvert(namespacePrefix));
    return self;
}

-(QTrackNamespace)getNamespacePrefix
{
    assert(handlerPtr);
    return nsConvert(handlerPtr->GetPrefix());
}

-(QSubscribeNamespaceHandlerStatus)getStatus
{
    assert(handlerPtr);
    return static_cast<QSubscribeNamespaceHandlerStatus>(handlerPtr->GetStatus());
}

-(void)setCallbacks:(id<QSubscribeNamespaceHandlerCallbacks>)callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

@end

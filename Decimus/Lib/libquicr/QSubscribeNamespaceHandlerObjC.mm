// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import <Foundation/Foundation.h>
#import "QSubscribeNamespaceHandlerObjC.h"
#import "QSubscribeTrackHandlerObjC.h"

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

bool QSubscribeNamespaceHandler::IsTrackAcceptable(const quicr::FullTrackName& name) const
{
    if (_callbacks) {
        return [_callbacks isTrackAcceptable:ftnConvert(name)];
    }
    return quicr::SubscribeNamespaceHandler::IsTrackAcceptable(name);
}

std::shared_ptr<quicr::SubscribeTrackHandler>
QSubscribeNamespaceHandler::CreateHandler(const quicr::messages::PublishAttributes& attributes)
{
    if (_callbacks) {
        QSubscribeTrackHandlerObjC* handler =
            [_callbacks createHandler:ftnConvert(attributes.track_full_name)
                           trackAlias:attributes.track_alias
                             priority:attributes.priority
                           groupOrder:static_cast<QGroupOrder>(attributes.group_order)
                           filterType:static_cast<QFilterType>(attributes.filter_type)];
        if (handler) {
            return handler->handlerPtr;
        }
    }
    return quicr::SubscribeNamespaceHandler::CreateHandler(attributes);
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

-(BOOL)isTrackAcceptable:(id<QFullTrackName>)fullTrackName
{
    assert(handlerPtr);
    return handlerPtr->IsTrackAcceptable(ftnConvert(fullTrackName));
}

-(void)setCallbacks:(id<QSubscribeNamespaceHandlerCallbacks>)callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

@end

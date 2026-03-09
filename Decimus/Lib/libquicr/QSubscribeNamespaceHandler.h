// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeNamespaceHandler_h
#define QSubscribeNamespaceHandler_h

#include "quicr/subscribe_namespace_handler.h"
#include "quicr/detail/attributes.h"
#import "QSubscribeNamespaceHandlerCallbacks.h"

@class QSubscribeNamespaceHandlerObjC;

class QSubscribeNamespaceHandler : public quicr::SubscribeNamespaceHandler
{
public:
    explicit QSubscribeNamespaceHandler(const quicr::TrackNamespace& prefix,
                                        const std::optional<quicr::messages::Filter>& filter = std::nullopt);

    void StatusChanged(Status status) override;

    void SetCallbacks(id<QSubscribeNamespaceHandlerCallbacks> callbacks);
    void SetObjCWrapper(QSubscribeNamespaceHandlerObjC* wrapper);
    QSubscribeNamespaceHandlerObjC* GetObjCWrapper() const;

private:
    __weak id<QSubscribeNamespaceHandlerCallbacks> _callbacks;
    __weak QSubscribeNamespaceHandlerObjC* _objcWrapper;
};

#endif /* QSubscribeNamespaceHandler_h */

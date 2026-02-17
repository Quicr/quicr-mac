// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeNamespaceHandler_h
#define QSubscribeNamespaceHandler_h

#include "quicr/subscribe_namespace_handler.h"
#import "QSubscribeNamespaceHandlerCallbacks.h"

class QSubscribeNamespaceHandler : public quicr::SubscribeNamespaceHandler
{
public:
    explicit QSubscribeNamespaceHandler(const quicr::TrackNamespace& prefix);

    void StatusChanged(Status status) override;

    void SetCallbacks(id<QSubscribeNamespaceHandlerCallbacks> callbacks);

private:
    __weak id<QSubscribeNamespaceHandlerCallbacks> _callbacks;
};

#endif /* QSubscribeNamespaceHandler_h */

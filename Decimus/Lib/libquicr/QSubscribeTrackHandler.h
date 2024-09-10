// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeTrackHandler_h
#define QSubscribeTrackHandler_h

#include "quicr/subscribe_track_handler.h"
#include "quicr/track_name.h"
#import "QSubscribeTrackHandlerCallbacks.h"

class QSubscribeTrackHandler : public quicr::SubscribeTrackHandler
{
public:
    QSubscribeTrackHandler(const quicr::FullTrackName& full_track_name);

    // Callbacks.
    void StatusChanged(Status status);
    void ObjectReceived(const quicr::ObjectHeaders& object_headers, quicr::BytesSpan data);
    void PartialObjectReceived(const quicr::ObjectHeaders& object_headers, quicr::BytesSpan data);

    // Methods.
    void SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks);


private:
    __weak id<QSubscribeTrackHandlerCallbacks> _callbacks;
};

#endif /* QSubscribeTrackHandler_h */

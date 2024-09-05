// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeTrackHandler_h
#define QSubscribeTrackHandler_h

#include "moq/subscribe_track_handler.h"
#include "moq/track_name.h"
#import "QSubscribeTrackHandlerCallbacks.h"

class QSubscribeTrackHandler : public moq::SubscribeTrackHandler
{
public:
    QSubscribeTrackHandler(const moq::FullTrackName& full_track_name);
    
    // Callbacks.
    void StatusChanged(Status status);
    void ObjectReceived(const moq::ObjectHeaders& object_headers, Span<uint8_t> data);
    void PartialObjectReceived(const moq::ObjectHeaders& object_headers, Span<uint8_t> data);

    // Methods.
    void SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks);
    
    
private:
    __weak id<QSubscribeTrackHandlerCallbacks> _callbacks;
};

#endif /* QSubscribeTrackHandler_h */

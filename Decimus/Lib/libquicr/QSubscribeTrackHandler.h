//
//  QSubscribTrackHandler.h
//  Decimus
//
//  Created by Scott Henning on 8/27/24.
//

#ifndef QSubscribeTrackHandler_h
#define QSubscribeTrackHandler_h

#include "moq/subscribe_track_handler.h"

class QSubscribeTrackHandler : moq::SubscribeTrackHandler
{
public:
    QSubscribeTrackHandler(const FullTrackName& full_track_name,
                                               TrackMode track_mode,
                                               uint8_t default_priority,
                                               uint832_t default_ttl);
    
    void StatusChanged(Status status);
    
    void SetCallbacks(id<QPublishTrackHandlerCallbacks> callbacks);
    
private:
    id<QSubscribeTrackHandlerCallbacks> _callbacks;
    
};


#endif /* QSubscribeTrackHandler_h */

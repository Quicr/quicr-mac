#ifndef QPublishTrackHandler_h
#define QPublishTrackHandler_h

#include "moq/publish_track_handler.h"
#include "moq/track_name.h"

#import "QPublishTrackHandlerCallbacks.h"

class QPublishTrackHandler : public moq::PublishTrackHandler
{
public:
    QPublishTrackHandler(const moq::FullTrackName& full_track_name,
                         moq::TrackMode track_mode,
                         uint8_t default_priority,
                         uint32_t default_ttl);

    void StatusChanged(Status status);

    void SetCallbacks(id<QPublishTrackHandlerCallbacks> callbacks);
    
private:
    id<QPublishTrackHandlerCallbacks> _callbacks;
};


#endif /* QPublishTrackHandler_h */

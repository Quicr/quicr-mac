#import <Foundation/Foundation.h>
#import "QPublishTrackHandlerObjC.h"

@implementation QPublishTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (QFullTrackName) full_track_name trackMode: (QTrackMode) track_mode defaultPriority: (uint8_t) priority defaultTTL: (uint32_t) ttl
{
    auto cnamespace = [full_track_name.nameSpace UTF8String];
    auto cnamespaceLength = [full_track_name.nameSpace length];
    std::vector<std::uint8_t> name_space(cnamespace, cnamespace + cnamespaceLength);
    
    auto cname = [full_track_name.nameSpace UTF8String];
    auto cnameLength = [full_track_name.nameSpace length];
    std::vector<std::uint8_t> name(cname, cname + cnameLength);
    
    moq::FullTrackName fullTrackName {
        .name_space = name_space,
        .name = name
    };
    moq::TrackMode moqTrackMode = (moq::TrackMode)track_mode;
    
    // allocate handler...
    handlerPtr = std::make_shared<QPublishTrackHandler>(fullTrackName, moqTrackMode, priority, ttl);
    return self;
}


-(void) setCallbacks: (id<QPublishTrackHandlerCallbacks>) callbacks
{
    if (handlerPtr)
    {
        handlerPtr->SetCallbacks(callbacks);
    }
}

// C++

QPublishTrackHandler::QPublishTrackHandler(const moq::FullTrackName& full_track_name,
                                           moq::TrackMode track_mode,
                                           uint8_t default_priority,
                                           uint32_t default_ttl) : moq::PublishTrackHandler(full_track_name, track_mode, default_priority, default_ttl)
{
}

void QPublishTrackHandler::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: (int) status];
    }
}

void QPublishTrackHandler::SetCallbacks(id<QPublishTrackHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

@end

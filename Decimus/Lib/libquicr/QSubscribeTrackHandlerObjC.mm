#import <Foundation/Foundation.h>
#import "QSubscribeTrackHandlerObjC.h"
#import "QCommon.h"

@implementation QSubscribeTrackHandlerObjC : NSObject

-(id) initWithFullTrackName: (QFullTrackName) full_track_name
{
    moq::FullTrackName fullTrackName = ftnConvert(full_track_name);
    handlerPtr = std::make_shared<QSubscribeTrackHandler>(fullTrackName);
    return self;
}

-(QSubscribeTrackHandlerStatus) getStatus {
    assert(handlerPtr);
    auto status = handlerPtr->GetStatus();
    return static_cast<QSubscribeTrackHandlerStatus>(status);
}

-(void) setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks
{
    assert(handlerPtr);
    handlerPtr->SetCallbacks(callbacks);
}

@end

// C++

QSubscribeTrackHandler::QSubscribeTrackHandler(const moq::FullTrackName& full_track_name): moq::SubscribeTrackHandler(full_track_name) { }

void QSubscribeTrackHandler::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QSubscribeTrackHandlerStatus>(status)];
    }
}

void QSubscribeTrackHandler::ObjectReceived(const moq::ObjectHeaders& object_headers,
                                            Span<uint8_t> data)
{
    if (_callbacks)
    {
        // TODO: Translate the headers.
        QObjectHeaders headers;
        [_callbacks objectReceived:headers data:data.data() length:data.size()];
    }
}

void QSubscribeTrackHandler::PartialObjectReceived(const moq::ObjectHeaders& object_headers,
                                                   Span<uint8_t> data)
{
    if (_callbacks)
    {
        // TODO: Translate the headers.
        QObjectHeaders headers;
        [_callbacks partialObjectReceived:headers data:data.data() length:data.size()];
    }
}

void QSubscribeTrackHandler::SetCallbacks(id<QSubscribeTrackHandlerCallbacks> callbacks)
{
    _callbacks = callbacks;
}

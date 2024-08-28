#import <Foundation/Foundation.h>
#import "QClient.h"
#import "QClientObjC.h"
#include <memory>

@implementation QClientObjC : NSObject

-(id)initWithConfig: (QClientConfig) config
{
    moq::ClientConfig moqConfig;
    qClientPtr = std::make_unique<QClient>(moqConfig);
    return self;
}

-(QClientStatus)connect
{
    assert(qClientPtr);
    auto status = qClientPtr->Connect();
    return static_cast<QClientStatus>(status);
}

-(QClientStatus) disconnect
{
    assert(qClientPtr);
    auto status = qClientPtr->Disconnect();
    return static_cast<QClientStatus>(status);
}

-(void)publishTrackWithHandler: (QPublishTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::PublishTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->PublishTrack(handler);
    }
}

-(void)unpublishTrackWithHandler: (QPublishTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::PublishTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->UnpublishTrack(handler);
    }
}

-(void)subscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::SubscribeTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->SubscribeTrack(handler);
    }
}

-(void)unsubscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) trackHandler
{
    assert(qClientPtr);
    if (trackHandler->handlerPtr)
    {
        auto handler = std::static_pointer_cast<moq::SubscribeTrackHandler>(trackHandler->handlerPtr);
        qClientPtr->UnsubscribeTrack(handler);
    }
}

-(QPublishAnnounceStatus) publishAnnounce: (NSData*) trackNamespace
{
    assert(qClientPtr);
    auto ptr = static_cast<const std::uint8_t*>(trackNamespace.bytes);
    moq::TrackNamespace name_space(ptr, ptr + trackNamespace.length);
    auto status = qClientPtr->PublishAnnounce(name_space);
    return static_cast<QPublishAnnounceStatus>(status);
}

-(void) publishUnannounce: (NSData*) trackNamespace
{
    assert(qClientPtr);
    auto ptr = static_cast<const std::uint8_t*>(trackNamespace.bytes);
    moq::TrackNamespace name_space(ptr, ptr + trackNamespace.length);
    qClientPtr->PublishUnannounce(name_space);
}

-(void)setCallbacks: (id<QClientCallbacks>) callbacks
{
    assert(qClientPtr);
    qClientPtr->SetCallbacks(callbacks);
}

-(QPublishAnnounceStatus) getAnnounceStatus: (NSData*) trackNamespace
{
    assert(qClientPtr);
    auto ptr = static_cast<const std::uint8_t*>(trackNamespace.bytes);
    moq::TrackNamespace name_space(ptr, ptr + trackNamespace.length);
    auto status = qClientPtr->GetAnnounceStatus(name_space);
    return static_cast<QPublishAnnounceStatus>(status);
}

// C++

QClient::QClient(moq::ClientConfig config) : moq::Client(config)
{
}

QClient::~QClient()
{
}

void QClient::StatusChanged(Status status)
{
    if (_callbacks)
    {
        [_callbacks statusChanged: static_cast<QClientStatus>(status) ];
    }
}

void QClient::SetCallbacks(id<QClientCallbacks> callbacks)
{
    _callbacks = callbacks;
}

@end


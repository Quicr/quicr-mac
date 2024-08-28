#import <Foundation/Foundation.h>
#import "QClient.h"
#import "QClientObjC.h"
#include <memory>

@implementation QClientObjC : NSObject

-(id)initWithConfig: (ClientConfig) config
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

-(void)setCallbacks: (id<QClientCallbacks>) callbacks
{
    assert(qClientPtr);
    qClientPtr->SetCallbacks(callbacks);
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


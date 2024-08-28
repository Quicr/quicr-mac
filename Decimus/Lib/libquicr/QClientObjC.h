#ifndef QClientObjC_h
#define QClientObjC_h

#ifdef __cplusplus
#include "QClient.h"
#include <memory>
#endif

#import "QPublishTrackHandlerObjC.h"
#import "QClientCallbacks.h"

@interface QClientObjC : NSObject
{
#ifdef __cplusplus
   std::unique_ptr<QClient> qClientPtr;
#endif
}


typedef struct ClientConfig {

} ClientConfig;


-(id)initWithConfig: (ClientConfig) config;

-(QClientStatus)connect;
-(QClientStatus)disconnect;

-(void)publishTrackWithHandler: (QPublishTrackHandlerObjC*) handler;

-(void)setCallbacks: (id<QClientCallbacks>) callbacks;

@end

#endif /* QClientObjC_h */

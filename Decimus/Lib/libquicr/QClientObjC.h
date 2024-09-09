// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QClientObjC_h
#define QClientObjC_h

#ifdef __cplusplus
#include "QClient.h"
#include <memory>
#endif

#import "QPublishTrackHandlerObjC.h"
#import "QSubscribeTrackHandlerObjC.h"
#import "QClientCallbacks.h"
#import "TransportConfig.h"

#import <Foundation/Foundation.h>

@interface QClientObjC : NSObject
{
#ifdef __cplusplus
   std::unique_ptr<QClient> qClientPtr;
#endif
}

typedef struct QClientConfig {
    const char* connectUri;
    const char* endpointId;
    TransportConfig transportConfig;
    uint64_t metricsSampleMs;
} QClientConfig;

typedef void(*LogCallback)(uint8_t, NSString*, bool);

-(id)initWithConfig: (QClientConfig) config logCallback:(LogCallback) logCallback;

-(QClientStatus)connect;
-(QClientStatus)disconnect;

-(void) publishTrackWithHandler: (QPublishTrackHandlerObjC*) handler;
-(void) unpublishTrackWithHandler: (QPublishTrackHandlerObjC*) handler;

-(void) publishAnnounce: (NSData*) trackNamespace;
-(void) publishUnannounce: (NSData*) trackNamespace;

-(void) subscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) handler;
-(void) unsubscribeTrackWithHandler: (QSubscribeTrackHandlerObjC*) handler;

-(QPublishAnnounceStatus) getAnnounceStatus: (NSData*) trackNamespace;

-(void)setCallbacks: (id<QClientCallbacks>) callbacks;

@end

#endif /* QClientObjC_h */

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
#import "QFetchTrackHandlerObjC.h"
#import "QClientCallbacks.h"
#import "TransportConfig.h"

#import <Foundation/Foundation.h>

typedef struct QClientConfig {
    const char* _Nonnull connectUri;
    const char* _Nonnull endpointId;
    TransportConfig transportConfig;
    uint64_t metricsSampleMs;
} QClientConfig;

@protocol MoqClient
- (QClientStatus)connect;
- (QClientStatus)disconnect;
- (void)publishTrackWithHandler:(QPublishTrackHandlerObjC * _Nonnull)handler;
- (void)unpublishTrackWithHandler:(QPublishTrackHandlerObjC * _Nonnull)handler;
- (void)publishAnnounce:(NSData * _Nonnull)trackNamespace;
- (void)publishUnannounce:(NSData * _Nonnull)trackNamespace;
- (void)subscribeTrackWithHandler:(QSubscribeTrackHandlerObjC * _Nonnull)handler;
- (void)unsubscribeTrackWithHandler:(QSubscribeTrackHandlerObjC * _Nonnull)handler;
- (void)fetchTrackWithHandler:(QFetchTrackHandlerObjC * _Nonnull)handler;
- (void)cancelFetchTrackWithHandler:(QFetchTrackHandlerObjC * _Nonnull)handler;
- (QPublishAnnounceStatus)getAnnounceStatus:(NSData * _Nonnull)trackNamespace;
- (void)setCallbacks:(id <QClientCallbacks> _Nonnull)callbacks;
@end

@interface QClientObjC : NSObject<MoqClient>
{
#ifdef __cplusplus
   std::shared_ptr<QClient> qClientPtr;
#endif
}

- (nonnull instancetype)initWithConfig:(QClientConfig)config;

@end

#endif /* QClientObjC_h */

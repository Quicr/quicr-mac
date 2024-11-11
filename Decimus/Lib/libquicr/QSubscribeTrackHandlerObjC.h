// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QSubscribeTrackHandlerObjC_h
#define QSubscribeTrackHandlerObjC_h

#ifdef __cplusplus
#include "QSubscribeTrackHandler.h"
#endif

#import <Foundation/Foundation.h>
#import "QCommon.h"
#import "QSubscribeTrackHandlerCallbacks.h"
#import "QFullTrackName.h"

typedef NS_ENUM(uint8_t, QGroupOrder) {
    kQGroupOrderOriginalPublisherOrder,
    kQGroupOrderAscending,
    kQGroupOrderDescending
};

@interface QSubscribeTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QSubscribeTrackHandler> handlerPtr;
#endif
}

-(id _Nonnull) initWithFullTrackName: (id<QFullTrackName> _Nonnull) full_track_name priority: (uint8_t) priority groupOrder: (QGroupOrder) groupOrder;
-(QSubscribeTrackHandlerStatus) getStatus;
-(id<QFullTrackName> _Nonnull) getFullTrackName;
-(void)setCallbacks: (id<QSubscribeTrackHandlerCallbacks> _Nonnull) callbacks;

@end

#endif /* QSubscribeTrackHandlerObjC_h */

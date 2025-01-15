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

@interface QSubscribeTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QSubscribeTrackHandler> handlerPtr;
#endif
}

-(id _Nonnull) initWithFullTrackName: (id<QFullTrackName> _Nonnull) full_track_name priority: (uint8_t) priority groupOrder: (QGroupOrder) groupOrder filterType: (QFilterType) filterType;
-(QSubscribeTrackHandlerStatus) getStatus;
-(id<QFullTrackName> _Nonnull) getFullTrackName;
-(uint8_t) getPriority;
-(QGroupOrder) getGroupOrder;
-(QFilterType) getFilterType;
-(void)setCallbacks: (id<QSubscribeTrackHandlerCallbacks> _Nonnull) callbacks;

@end

#endif /* QSubscribeTrackHandlerObjC_h */

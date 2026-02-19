// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#ifndef QFetchTrackHandlerObjC_h
#define QFetchTrackHandlerObjC_h

#ifdef __cplusplus
#include "QFetchTrackHandler.h"
#endif

#import <Foundation/Foundation.h>
#import "QCommon.h"
#import "QSubscribeTrackHandlerCallbacks.h"
#import "QFullTrackName.h"
#import "QLocation.h"

@interface QFetchTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QFetchTrackHandler> handlerPtr;
#endif
}

-(id _Nonnull) initWithFullTrackName: (id<QFullTrackName> _Nonnull) full_track_name
                            priority: (uint8_t) priority
                          groupOrder: (QGroupOrder) groupOrder
                       startLocation: (id<QLocation> _Nonnull) startLocation
                         endLocation: (id<QFetchEndLocation> _Nonnull) endLocation;
-(id<QLocation> _Nonnull) getStartLocation;
-(id<QFetchEndLocation> _Nonnull) getEndLocation;
-(QSubscribeTrackHandlerStatus) getStatus;
-(uint8_t) getPriority;
-(QGroupOrder) getGroupOrder;
-(QFilterType) getFilterType;
-(id<QFullTrackName> _Nonnull) getFullTrackName;
-(void)setCallbacks: (id<QSubscribeTrackHandlerCallbacks> _Nonnull) callbacks;

@end

#endif /* QFetchTrackHandlerObjC_h */

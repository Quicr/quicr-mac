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
#import "QLocation.h"

@interface QSubscribeTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QSubscribeTrackHandler> handlerPtr;
#endif
}

-(id _Nonnull) initWithFullTrackName: (id<QFullTrackName> _Nonnull) full_track_name priority: (uint8_t) priority groupOrder: (QGroupOrder) groupOrder filterType: (QFilterType) filterType;
-(QSubscribeTrackHandlerStatus) getStatus;
-(void) setPriority: (uint8_t) priority;
-(id<QFullTrackName> _Nonnull) getFullTrackName;
-(uint8_t) getPriority;
-(QGroupOrder) getGroupOrder;
-(QFilterType) getFilterType;
-(id<QLocation> _Nullable) getLatestLocation;
-(void) requestNewGroup;
-(void)setCallbacks: (id<QSubscribeTrackHandlerCallbacks> _Nonnull) callbacks;
-(void)setDeliveryTimeout:(uint64_t) timeout;
typedef void (*NewGroupCallback)(void* _Nonnull);
#if DEBUG
-(void) setNewGroupCallback: (NewGroupCallback _Nonnull) callback context: (void* _Nonnull) context;
#endif

@end

#endif /* QSubscribeTrackHandlerObjC_h */

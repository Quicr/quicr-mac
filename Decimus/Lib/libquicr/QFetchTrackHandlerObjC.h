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
                          startGroup: (uint64_t) startGroup
                            endGroup: (uint64_t) endGroup
                         startObject: (uint64_t) startObject
                           endObject: (uint64_t) endObject;
-(uint64_t) getStartGroup;
-(uint64_t) getEndGroup;
-(uint64_t) getStartObject;
-(uint64_t) getEndObject;
-(QSubscribeTrackHandlerStatus) getStatus;
-(uint8_t) getPriority;
-(QGroupOrder) getGroupOrder;
-(QFilterType) getFilterType;
-(id<QFullTrackName> _Nonnull) getFullTrackName;
-(void)setCallbacks: (id<QSubscribeTrackHandlerCallbacks> _Nonnull) callbacks;

@end

#endif /* QFetchTrackHandlerObjC_h */

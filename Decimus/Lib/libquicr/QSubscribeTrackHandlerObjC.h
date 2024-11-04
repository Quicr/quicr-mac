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

@interface QSubscribeTrackHandlerObjC : NSObject
{
#ifdef __cplusplus
@public
    std::shared_ptr<QSubscribeTrackHandler> handlerPtr;
#endif
}

-(id) initWithFullTrackName: (QFullTrackName) full_track_name;
-(QSubscribeTrackHandlerStatus) getStatus;
-(QFullTrackName) getFullTrackName;
-(void)setCallbacks: (id<QSubscribeTrackHandlerCallbacks>) callbacks;

@end

#endif /* QSubscribeTrackHandlerObjC_h */

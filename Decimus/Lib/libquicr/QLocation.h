// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause


#ifndef QLocation_h
#define QLocation_h

#import <Foundation/Foundation.h>

@protocol QLocation
@property (readonly) uint64_t group;
@property (readonly) uint64_t object;
@end

@interface QLocationImpl: NSObject<QLocation>
@property uint64_t group;
@property uint64_t object;
-(instancetype _Nonnull) initWithGroup: (uint64_t) group object: (uint64_t) object;
@end

#endif

// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QTrackFilter.h"

@implementation QTrackFilterObjC

- (id _Nonnull)initWithPropertyType:(uint64_t)propertyType
                  maxTracksSelected:(uint64_t)maxTracksSelected
                            timeout:(uint64_t)timeout {
    self = [super init];
    _propertyType = propertyType;
    _maxTracksSelected = maxTracksSelected;
    _timeout = timeout;
    return self;
}

@end

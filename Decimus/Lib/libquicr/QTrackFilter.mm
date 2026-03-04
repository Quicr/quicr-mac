// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QTrackFilter.h"

@implementation QTrackFilterObjC

- (id _Nonnull)initWithPropertyType:(uint64_t)propertyType
                   maxTracksSelected:(uint64_t)maxTracksSelected
                 maxTracksDeselected:(uint64_t)maxTracksDeselected
                    maxTimeSelected:(uint64_t)maxTimeSelected {
    self = [super init];
    _propertyType = propertyType;
    _maxTracksSelected = maxTracksSelected;
    _maxTracksDeselected = maxTracksDeselected;
    _maxTimeSelected = maxTimeSelected;
    return self;
}

@end

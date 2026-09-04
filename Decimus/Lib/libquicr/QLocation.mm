// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#include <stdint.h>
#import "QLocation.h"

@implementation QLocationImpl

-(instancetype _Nonnull) initWithGroup:(uint64_t) group object:(uint64_t) object {
    self = [super init];
    if (self) {
        _group = group;
        _object = object;
    }
    return self;
}

-(BOOL) isEqual:(id _Nullable) object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[QLocationImpl class]]) {
        return NO;
    }

    QLocationImpl* location = (QLocationImpl*) object;
    return self.group == location.group && self.object == location.object;
}

-(NSUInteger) hash {
    return @(self.group).hash ^ @(self.object).hash;
}

@end

@implementation QFetchEndLocationImpl

-(instancetype _Nonnull) initWithGroup:(uint64_t) group object:(NSNumber* _Nullable) object {
    self.group = group;
    self.object = object;
    return self;
}

@end

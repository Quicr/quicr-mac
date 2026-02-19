// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#include <stdint.h>
#import "QLocation.h"

@implementation QLocationImpl

-(instancetype _Nonnull) initWithGroup:(uint64_t) group object:(uint64_t) object {
    self.group = group;
    self.object = object;
    return self;
}

@end

@implementation QFetchEndLocationImpl

-(instancetype _Nonnull) initWithGroup:(uint64_t) group object:(NSNumber* _Nullable) object {
    self.group = group;
    self.object = object;
    return self;
}

@end

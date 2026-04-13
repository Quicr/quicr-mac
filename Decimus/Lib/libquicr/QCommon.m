// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QCommon.h"

@implementation QStreamHeaderProperties

-(instancetype) initWithExtensions: (bool) extensions
                    subgroupIdMode: (QSubgroupIdMode) subgroupIdMode
                        endOfGroup: (bool) endOfGroup
                   defaultPriority: (bool) defaultPriority {
    self = [super init];
    if (self) {
        _extensions = extensions;
        _subgroupIdMode = subgroupIdMode;
        _endOfGroup = endOfGroup;
        _defaultPriority = defaultPriority;
    }
    return self;
}

@end

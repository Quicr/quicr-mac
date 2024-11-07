// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QFullTrackName.h"

// Empty implementation for QFullTrackName
@implementation QFullTrackNameImpl

-(instancetype _Nonnull) initWithNamespace: (NSData* _Nonnull) nameSpace name: (NSData* _Nonnull) name {
    self.nameSpace = nameSpace;
    self.name = name;
    return self;
}

@end

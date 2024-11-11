// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

#import "QFullTrackName.h"

@implementation QFullTrackNameImpl

-(instancetype _Nonnull) initWithNamespace: (QTrackNamespace) nameSpace name: (QName) name {
    self.nameSpace = nameSpace;
    self.name = name;
    return self;
}

@end

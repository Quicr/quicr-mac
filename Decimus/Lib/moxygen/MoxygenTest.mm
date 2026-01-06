// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#import "MoxygenTest.h"

// Moxygen headers
#include <moxygen/MoQFramer.h>
#include <moxygen/MoQCodec.h>

@implementation MoxygenTest

+ (NSString *)testMoxygenIntegration {
    // Get the current and supported MoQT draft versions from moxygen constants
    uint64_t currentVersion = moxygen::kVersionDraftCurrent;

    // Build supported versions string from the kSupportedVersions array
    NSMutableArray *versions = [NSMutableArray array];
    for (uint64_t v : moxygen::kSupportedVersions) {
        [versions addObject:[NSString stringWithFormat:@"draft-%llu", (unsigned long long)(v & 0xFF)]];
    }

    NSString *result = [NSString stringWithFormat:@"Moxygen loaded - Current: draft-%llu, Supported: [%@]",
                        (unsigned long long)(currentVersion & 0xFF),
                        [versions componentsJoinedByString:@", "]];
    return result;
}

@end

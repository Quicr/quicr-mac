// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#ifndef MoxygenTest_h
#define MoxygenTest_h

#import <Foundation/Foundation.h>

/// Simple test class to verify moxygen framework integration.
/// This validates that the xcframework links correctly and headers are accessible.
@interface MoxygenTest : NSObject

/// Test that moxygen headers can be included and basic types work.
/// Returns a string describing the moxygen version/status.
+ (NSString *)testMoxygenIntegration;

@end

#endif /* MoxygenTest_h */

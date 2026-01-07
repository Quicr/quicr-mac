// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#ifndef MoxygenClientObjC_h
#define MoxygenClientObjC_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MoxygenConnectionStatus) {
    MoxygenConnectionStatusDisconnected,
    MoxygenConnectionStatusConnecting,
    MoxygenConnectionStatusConnected,
    MoxygenConnectionStatusFailed
};

@protocol MoxygenClientCallbacks <NSObject>
- (void)onStatusChanged:(MoxygenConnectionStatus)status;
- (void)onError:(NSString *)error;
@end

@interface MoxygenClientConfig : NSObject
@property (nonatomic, copy) NSString *connectURL;
@property (nonatomic) NSTimeInterval connectTimeout;
@end

@interface MoxygenClientObjC : NSObject

@property (nonatomic, readonly) MoxygenConnectionStatus status;

- (instancetype)initWithConfig:(MoxygenClientConfig *)config;
- (void)setCallbacks:(id<MoxygenClientCallbacks> _Nullable)callbacks;
- (void)connect;
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END

#endif /* MoxygenClientObjC_h */

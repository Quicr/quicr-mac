// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#ifndef MoxygenClient_h
#define MoxygenClient_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include <memory>
#include <string>
#include <functional>
#endif

NS_ASSUME_NONNULL_BEGIN

/// Connection status for the moxygen client
typedef NS_ENUM(NSInteger, MoxygenConnectionStatus) {
    MoxygenConnectionStatusDisconnected = 0,
    MoxygenConnectionStatusConnecting,
    MoxygenConnectionStatusConnected,
    MoxygenConnectionStatusFailed
};

/// Callback protocol for moxygen client events
@protocol MoxygenClientDelegate <NSObject>
- (void)moxygenClient:(id)client connectionStatusChanged:(MoxygenConnectionStatus)status;
- (void)moxygenClient:(id)client connectionFailedWithError:(NSString *)error;
@optional
- (void)moxygenClientReceivedGoaway:(id)client newUri:(NSString *)newUri;
@end

/// Configuration for moxygen client connection
@interface MoxygenClientConfig : NSObject
@property (nonatomic, copy) NSString *connectUrl;
@property (nonatomic, assign) NSTimeInterval connectTimeoutMs;
@property (nonatomic, assign) NSTimeInterval transactionTimeoutSec;
@property (nonatomic, assign) BOOL useLegacyAlpn;

- (instancetype)initWithUrl:(NSString *)url;
@end

/// Objective-C wrapper for the moxygen MoQ client
@interface MoxygenClient : NSObject

@property (nonatomic, weak, nullable) id<MoxygenClientDelegate> delegate;
@property (nonatomic, readonly) MoxygenConnectionStatus connectionStatus;
@property (nonatomic, readonly) NSString *supportedVersions;

- (instancetype)initWithConfig:(MoxygenClientConfig *)config;

/// Connect to the MoQ relay server
- (void)connect;

/// Disconnect from the MoQ relay server
- (void)disconnect;

/// Get info about the current connection (for debugging)
- (nullable NSString *)connectionInfo;

@end

NS_ASSUME_NONNULL_END

#endif /* MoxygenClient_h */

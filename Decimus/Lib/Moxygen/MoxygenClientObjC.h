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

typedef NS_ENUM(NSInteger, MoxygenSubscribeStatus) {
    MoxygenSubscribeStatusOk,
    MoxygenSubscribeStatusError,
    MoxygenSubscribeStatusDone
};

typedef NS_ENUM(NSInteger, MoxygenGroupOrder) {
    MoxygenGroupOrderDefault = 0,
    MoxygenGroupOrderOldestFirst = 1,
    MoxygenGroupOrderNewestFirst = 2
};

@protocol MoxygenClientCallbacks <NSObject>
- (void)onStatusChanged:(MoxygenConnectionStatus)status;
- (void)onError:(NSString *)error;
@optional
/// Called when a subscriber subscribes to one of our published tracks
- (void)onSubscriberConnected:(NSArray<NSString *> *)trackNamespace
                    trackName:(NSString *)trackName;
@end

/// Callback protocol for receiving track data from subscriptions
@protocol MoxygenTrackCallback <NSObject>
/// Called when an object is received on the subscription
/// @param groupId The group ID
/// @param subgroupId The subgroup ID
/// @param objectId The object ID
/// @param data The object payload
/// @param extensions Mutable header extensions (may be nil)
/// @param immutableExtensions Immutable header extensions (may be nil)
/// @param receiveTicks The mach_absolute_time when the object was received
- (void)onObjectReceived:(uint64_t)groupId
              subgroupId:(uint64_t)subgroupId
                objectId:(uint64_t)objectId
                    data:(NSData *)data
              extensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable)extensions
    immutableExtensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable)immutableExtensions
            receiveTicks:(uint64_t)receiveTicks;

/// Called when subscription status changes
- (void)onSubscribeStatus:(MoxygenSubscribeStatus)status
                  message:(NSString * _Nullable)message;
@end

/// Object header for publishing
@interface MoxygenObjectHeader : NSObject
@property (nonatomic) uint64_t groupId;
@property (nonatomic) uint64_t subgroupId;
@property (nonatomic) uint64_t objectId;
@property (nonatomic) uint8_t priority;
@end

/// Subscribe request parameters
@interface MoxygenSubscribeRequest : NSObject
@property (nonatomic, copy) NSArray<NSString *> *trackNamespace;
@property (nonatomic, copy) NSString *trackName;
@property (nonatomic) uint8_t priority;
@property (nonatomic) MoxygenGroupOrder groupOrder;
@end

@interface MoxygenClientConfig : NSObject
@property (nonatomic, copy) NSString *connectURL;
@property (nonatomic) NSTimeInterval connectTimeout;
@end

@class MoxygenPublisher;

@interface MoxygenClientObjC : NSObject

@property (nonatomic, readonly) MoxygenConnectionStatus status;

- (instancetype)initWithConfig:(MoxygenClientConfig *)config;
- (void)setCallbacks:(id<MoxygenClientCallbacks> _Nullable)callbacks;
- (void)connect;
- (void)disconnect;

/// Subscribe to a track with the given request and callback
/// @param request The subscribe request containing namespace and track name
/// @param callback The callback to receive track data
/// @return YES if subscribe request was sent, NO on error
- (BOOL)subscribeWithRequest:(MoxygenSubscribeRequest *)request
                    callback:(id<MoxygenTrackCallback>)callback;

/// Announce a track namespace for publishing
/// @param trackNamespace The namespace to announce
/// @return YES if announce was successful, NO on error
- (BOOL)announceNamespace:(NSArray<NSString *> *)trackNamespace;

/// Create a publisher for a track
/// @param trackNamespace The namespace for the track
/// @param trackName The track name
/// @param groupOrder The group order for delivery
/// @return A publisher object, or nil on error
- (MoxygenPublisher * _Nullable)createPublisherWithNamespace:(NSArray<NSString *> *)trackNamespace
                                                   trackName:(NSString *)trackName
                                                  groupOrder:(MoxygenGroupOrder)groupOrder;

@end

/// Publisher for sending objects on a track
@interface MoxygenPublisher : NSObject

/// Publish an object on this track
/// @param header The object header (group, subgroup, object IDs)
/// @param data The object payload
/// @return YES if published successfully, NO on error
- (BOOL)publishObject:(MoxygenObjectHeader *)header
                 data:(NSData *)data;

/// Publish an object on this track with extensions
/// @param header The object header (group, subgroup, object IDs)
/// @param data The object payload
/// @param extensions Mutable header extensions (may be nil)
/// @param immutableExtensions Immutable header extensions (may be nil)
/// @return YES if published successfully, NO on error
- (BOOL)publishObject:(MoxygenObjectHeader *)header
                 data:(NSData *)data
           extensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable)extensions
  immutableExtensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>* _Nullable)immutableExtensions;

/// Close this publisher
- (void)close;

@end

NS_ASSUME_NONNULL_END

#endif /* MoxygenClientObjC_h */

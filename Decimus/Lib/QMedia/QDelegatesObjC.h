//
//  QMediaDelegates.h
//  Decimus
//
//  Created by Scott Henning on 5/11/23.
//
#ifndef QDelegatesObjC_h
#define QDelegatesObjC_h

#import <Foundation/Foundation.h>
#import "ProfileSet.h"

typedef unsigned TransportMode NS_TYPED_ENUM;
static TransportMode const TransportModeReliablePerTrack = 0;
static TransportMode const TransportModeReliablePerGroup = 1;
static TransportMode const TransportModeReliablePerObject = 2;
static TransportMode const TransportModeUnreliable = 3;
static TransportMode const TransportModeUsePublisher = 4;
static TransportMode const TransportModePause = 5;
static TransportMode const TransportModeResume = 6;

@protocol QSubscriptionDelegateObjC
- (int) prepare: (NSString*) sourceID label: (NSString*) label profileSet: (struct QClientProfileSet) profileSet transportMode: (TransportMode*) transportMode;
- (int) update: (NSString*) sourceID label: (NSString*) label profileSet: (struct QClientProfileSet) profileSet;
- (int) subscribedObject: (NSString*) name data: (const void*) data length: (size_t) length groupId: (UInt32) groupId objectId: (UInt16) objectId;
@end

@protocol QPublicationDelegateObjC
- (int) prepare: (NSString*) sourceID qualityProfile: (NSString*) qualityProfile transportMode: (TransportMode*) transportMode;
- (int) update: (NSString*) sourceID qualityProfile: (NSString*) qualityProfile;
- (void) publish: (bool) flag;
@end

@protocol QSubscriberDelegateObjC
- (id<QSubscriptionDelegateObjC>) allocateSubBySourceId: (NSString*) sourceId profileSet: (struct QClientProfileSet) profileSet;
- (int) removeBySourceId: (NSString*) sourceId;
@end

@protocol QPublisherDelegateObjC
- (id<QPublicationDelegateObjC>) allocatePubByNamespace: (NSString*) quicrNamepace sourceID: (NSString*) sourceID qualityProfile: (NSString*) qualityProfile;
- (int) removeByNamespace: (NSString*) quicrNamepace;
@end

@protocol QPublishObjectDelegateObjC
- (void) publishObject: (NSString*) quicrNamespace data: (NSData *) data group: (bool) groupFlag;
- (void) publishObject: (NSString*) quicrNamespace data: (const void *) dataPtr length: (size_t) dataLen group: (bool) groupFlag;
- (void) publishMeasurement: (NSString*) measurement;
@end

#endif /* QDelegatesObjC_h */

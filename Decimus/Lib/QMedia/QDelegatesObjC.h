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

@protocol QSubscriptionDelegateObjC
- (int) prepare: (NSString*) sourceID label: (NSString*) label profileSet: (struct QClientProfileSet) profileSet;
- (int) update: (NSString*) sourceID label: (NSString*) label profileSet: (struct QClientProfileSet) profileSet;
- (int) subscribedObject: (NSString*) name data: (NSData*) data groupId: (UInt32) groupId objectId: (UInt16) objectId;
@end

@protocol QPublicationDelegateObjC
- (int) prepare: (NSString*) sourceID qualityProfile: (NSString*) qualityProfile;
- (int) update: (NSString*) sourceID qualityProfile: (NSString*) qualityProfile;
- (void) publish: (bool) flag;
@end

@protocol QSubscriberDelegateObjC
- (id<QSubscriptionDelegateObjC>) allocateSubBySourceId: (NSString*) sourceId profileSet: (struct QClientProfileSet) profileSet;
- (int) removeByNamespace: (NSString*) quicrNamepace;
@end

@protocol QPublisherDelegateObjC
- (id<QPublicationDelegateObjC>) allocatePubByNamespace: (NSString*) quicrNamepace sourceID: (NSString*) sourceID qualityProfile: (NSString*) qualityProfile;
- (int) removeByNamespace: (NSString*) quicrNamepace;
@end

@protocol QPublishObjectDelegateObjC
- (void) publishObject: (NSString*) quicrNamespace data: (NSData *) data group: (bool) groupFlag;
@end

#endif /* QDelegatesObjC_h */

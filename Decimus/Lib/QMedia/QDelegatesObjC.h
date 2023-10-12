//
//  QMediaDelegates.h
//  Decimus
//
//  Created by Scott Henning on 5/11/23.
//
#ifndef QDelegatesObjC_h
#define QDelegatesObjC_h

#import <Foundation/Foundation.h>

@protocol QSubscriptionDelegateObjC
- (int) prepare: (NSString*) label qualityProfile: (NSString*) qualityProfile reliable: (bool*) reliable;
- (int) update: (NSString*) label qualityProfile: (NSString*) qualityProfile;
- (int) subscribedObject: (const void*) data length: (size_t) length groupId: (UInt32) groupId objectId: (UInt16) objectId;
@end

@protocol QPublicationDelegateObjC
- (int) prepare: (NSString*) qualityProfile reliable: (bool*) reliable;
- (int) update: (NSString*) qualityProfile;
- (void) publish: (bool) flag;
@end

@protocol QSubscriberDelegateObjC
- (id<QSubscriptionDelegateObjC>) allocateSubByNamespace: (NSString*) quicrNamepace qualityProfile: (NSString*) qualityProfile;
- (int) removeByNamespace: (NSString*) quicrNamepace;
@end

@protocol QPublisherDelegateObjC
- (id<QPublicationDelegateObjC>) allocatePubByNamespace: (NSString*) quicrNamepace sourceID: (NSString*) sourceID qualityProfile: (NSString*) qualityProfile;
- (int) removeByNamespace: (NSString*) quicrNamepace;
@end

@protocol QPublishObjectDelegateObjC
- (void) publishObject: (NSString*) quicrNamespace data: (NSData *) data group: (bool) groupFlag;
- (void) publishObject: (NSString*) quicrNamespace data: (const void *) dataPtr length: (size_t) dataLen group: (bool) groupFlag;
@end

#endif /* QDelegatesObjC_h */

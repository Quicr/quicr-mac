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
- (int) prepare: (NSString *) sourceId label: (NSString *) label qualityProfile: (NSString *) qualityProfile;
- (int) update: (NSString *) sourceId label: (NSString *) label qualityProfile: (NSString *) qualityProfile;
- (int) subscribedObject: (NSData *) data;
@end

@protocol QPublicationDelegateObjC
- (int) prepare: (NSString *) sourceId qualityProfile: (NSString *) qualityProfile;
- (int) update: (NSString *) sourceId qualityProfile: (NSString *) qualityProfile;
- (void) publish: (bool) flag;
@end

@protocol QSubscriberDelegateObjC
- (id) allocateSubByNamespace: (NSString *) quicrNamepace;
- (int) removeByNamespace:  (NSString *) quicrNamepace;
@end

@protocol QPublisherDelegateObjC
- (id) allocatePubByNamespace:  (NSString*) quicrNamepace;
- (int) removeByNamespace: (NSString*) quicrNamepace;
@end

@protocol QPublishObjectDelegateObjC
- (void) publishObject: (NSString *) quicrNamespace data: (void *) data len: (int) len;
@end

#endif /* QDelegatesObjC_h */

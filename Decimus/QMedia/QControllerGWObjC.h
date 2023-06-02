//
//  QMediaI.h
//  Decimus
//
//  Created by Scott Henning on 2/13/23.
//
#ifndef QControllerGWObc_h
#define QControllerGWObc_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include "QControllerGW.h"
#endif

#import "QDelegatesObjC.h"

@interface QControllerGWObjC : NSObject<QPublishObjectDelegateObjC>  {
#ifdef __cplusplus
    QControllerGW qControllerGW;
#endif
}
@property (nonatomic, weak)  id<QSubscriberDelegateObjC> subscriberDelegate;
@property (nonatomic, weak)  id<QPublisherDelegateObjC> publisherDelegate;

-(instancetype) init;
-(int) connect: (NSString*)remoteAddress
          port:(UInt16)remotePort
          protocol:(UInt8)protocol;
-(void) updateManifest: (NSString *) manifest;
@end


#endif /* QControllerGWObj_h */

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
#include <cantina/logger.h>
#endif

#import "QDelegatesObjC.h"
#import "TransportConfig.h"

typedef void(*CantinaLogCallback)(uint8_t, NSString*, bool);

@interface QControllerGWObjC<PubDelegate: id<QPublisherDelegateObjC>,
                             SubDelegate: id<QSubscriberDelegateObjC>> : NSObject<QPublishObjectDelegateObjC> {
#ifdef __cplusplus
    QControllerGW qControllerGW;
#endif
}

@property (nonatomic, strong) PubDelegate publisherDelegate;
@property (nonatomic, strong) SubDelegate subscriberDelegate;

-(instancetype) initCallback:(CantinaLogCallback)callback;
-(int) connect: (NSString*)remoteAddress
                port:(UInt16)remotePort
                protocol:(UInt8)protocol
                config:(TransportConfig)config;
-(void) close;
-(void) updateManifest: (NSString*)manifest;
-(void) setSubscriptionSingleOrdered:(bool) new_value;
-(void) setPublicationSingleOrdered:(bool) new_value;
@end

#endif /* QControllerGWObj_h */

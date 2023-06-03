//
//  QMediaI.m
//  Decimus
//
//  Created by Scott Henning on 2/13/23.
//
#include <stdlib.h>
#import <Foundation/Foundation.h>
#import "QControllerGWObjC.h"
#include "QControllerGW.h"
#include "QMediaDelegates.h"
#include "QDelegatesObjC.h"


// objective c
@implementation QControllerGWObjC

#import "QDelegatesObjC.h"

@synthesize subscriberDelegate;
@synthesize publisherDelegate;


- (id)init
{
    self = [super init];
    return self;
}

-(int) connect: (NSString *)remoteAddress port:(UInt16)remotePort protocol:(UInt8)protocol
{
    return qControllerGW.connect(std::string([remoteAddress UTF8String]), remotePort, protocol);
}

-(void)updateManifest: (NSString *) manifest
{
    qControllerGW.updateManifest(std::string([manifest UTF8String]));
}

-(void) setSubscriberDelegate:(id<QSubscriberDelegateObjC>)delegate
{
    qControllerGW.setSubscriberDelegate(delegate);
}

-(void) setPublisherDelegate:(id<QPublisherDelegateObjC>)delegate
{
    qControllerGW.setPublisherDelegate(delegate);
}

- (id)allocateSubByNamespace:(NSString *)quicrNamepace {
    return  [subscriberDelegate allocateSubByNamespace:quicrNamepace];
}

- (id)allocatePubByNamespace:(NSString *)quicrNamepace {
    return  [publisherDelegate allocatePubByNamespace:quicrNamepace];
}

- (int)removeByNamespace:(NSString *)quicrNamepace {
    // pass on to delegate...
    // fixme - which one?
    return 0;
}

- (void)publishObject:(NSString *)quicrNamespace data:(NSData *)data {
    qControllerGW.publishNamedObject(std::string([quicrNamespace UTF8String]), (std::uint8_t *)data.bytes, (int)data.length);
}

@end

// C++
QControllerGW::QControllerGW() // QControllerGWObjC *objcSelf): objcSelf(objcSelf)
{
}

int QControllerGW::connect(const std::string remote_address,
                       std::uint16_t remote_port,
                       std::uint16_t protocol)
{
    qController = std::make_unique<qmedia::QController>(subscriberDelegate, publisherDelegate);
    if (qController != nullptr)
    {
        quicr::RelayInfo::Protocol proto = quicr::RelayInfo::Protocol(protocol);
        std::string address = remote_address;
        qController->connect(address, remote_port, proto);
    }
    return 0;
}

QControllerGW::~QControllerGW()
{
}

void QControllerGW::updateManifest(const std::string manifest)
{
    qController->updateManifest(manifest);
}

void QControllerGW::setSubscriberDelegate(id<QSubscriberDelegateObjC> delegate)
{
    subscriberDelegate = std::make_shared<qclient::QMediaSubsciberDelegate>(delegate);
}

void QControllerGW::setPublisherDelegate(id<QPublisherDelegateObjC> delegate)
{
    publisherDelegate = std::make_shared<qclient::QMediaPublisherDelegate>(delegate) ;
}

// QPublishObject Delegate Method
void QControllerGW::publishNamedObject(const std::string quicrNamespaceString, std::uint8_t *data, int len)
{
    qController->publishNamedObject(std::string_view(quicrNamespaceString), data, len);
}

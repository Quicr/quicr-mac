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
    try {
        return qControllerGW.connect(std::string([remoteAddress UTF8String]), remotePort, protocol);
    } catch(const std::exception& e) {
        NSLog(@"QControllerGW::connect | ERROR | Failed to connect: %s", e.what());
        return -1;
    } catch(...) {
        NSLog(@"QControllerGW::connect | ERROR | Failed to connect due to unknown error");
        return -1;
    }
}

-(void) close
{
    qControllerGW.close();
}

-(void)updateManifest:(NSString*)manifest
{
    qControllerGW.updateManifest(std::string([manifest UTF8String]));
}

-(void)setSubscriberDelegate:(id<QSubscriberDelegateObjC>)delegate
{
    subscriberDelegate = delegate;
    qControllerGW.setSubscriberDelegate(delegate);
}

-(void)setPublisherDelegate:(id<QPublisherDelegateObjC>)delegate
{
    publisherDelegate = delegate;
    qControllerGW.setPublisherDelegate(delegate);
}

- (id<QSubscriptionDelegateObjC>)allocateSubByNamespace:(NSString *)quicrNamepace qualityProfile:(NSString*)qualityProfile {
    if (!subscriberDelegate) return nil;
    return  [subscriberDelegate allocateSubByNamespace:quicrNamepace qualityProfile:qualityProfile];
}

- (id<QPublicationDelegateObjC>)allocatePubByNamespace:(NSString *)quicrNamepace sourceID:(NSString*)sourceID qualityProfile:(NSString*)qualityProfile {
    if (!publisherDelegate) return nil;
    return  [publisherDelegate allocatePubByNamespace:quicrNamepace sourceID:sourceID qualityProfile:qualityProfile];
}

- (int)removeByNamespace:(NSString *)quicrNamepace {
    // pass on to delegate...
    // fixme - which one?
    return 0;
}

- (void)publishObject:(NSString *)quicrNamespace data:(NSData *)data group:(bool) groupFlag {
    qControllerGW.publishNamedObject(std::string([quicrNamespace UTF8String]), (std::uint8_t *)data.bytes, (int)data.length, groupFlag);
}

@end

// C++

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

void QControllerGW::close()
{
    if (qController)
    {
        qController->close();
    }
    else
    {
        NSLog(@"QControllerGW::close - qController nil");
    }
}

void QControllerGW::updateManifest(const std::string manifest)
{
    if (qController)
    {
        qController->updateManifest(manifest);
    }
    else
    {
        NSLog(@"QControllerGW::updateManifest - qController nil");
    }
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
void QControllerGW::publishNamedObject(const std::string quicrNamespaceString, std::uint8_t *data, int len, bool groupFlag)
{
    if (qController)
    {
        qController->publishNamedObject(std::string_view(quicrNamespaceString), data, len, groupFlag);
    }
    else
    {
        NSLog(@"QControllerGW::publishNamedObject - qController nil");
    }
}

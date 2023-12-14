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


- (id)initCallback:(CantinaLogCallback)callback
{
    self = [super init];
    self->qControllerGW.logger = std::make_shared<cantina::CustomLogger>([=](auto level, const std::string& msg, bool b) {
        NSString* m = [NSString stringWithCString:msg.c_str() encoding:[NSString defaultCStringEncoding]];
        callback(static_cast<uint8_t>(level), m, b);
    });

#ifdef DEBUG
    self->qControllerGW.logger->SetLogLevel(cantina::LogLevel::Debug);
#else
    self->qControllerGW.logger->SetLogLevel(cantina::LogLevel::Info);
#endif

    return self;
}

- (void)dealloc
{
    qControllerGW.logger->debug << "QControllerGW - dealloc" << std::flush;
}

-(int) connect: (NSString *)remoteAddress port:(UInt16)remotePort protocol:(UInt8)protocol config:(TransportConfig)config
{
    try {
        qtransport::TransportConfig tconfig;
        static_assert(std::is_trivially_copyable<qtransport::TransportConfig>() &&
                      std::is_trivially_copyable<TransportConfig>() &&
                      sizeof(tconfig) == sizeof(config));
        memcpy(&tconfig, &config, sizeof(tconfig));
        return qControllerGW.connect(std::string([remoteAddress UTF8String]), remotePort, protocol, tconfig);
    } catch(const std::exception& e) {
        qControllerGW.logger->error << "Failed to connect: " << e.what() << std::flush;
        return -1;
    } catch(...) {
        qControllerGW.logger->error << "Failed to connect due to unknown error" << std::flush;
        return -1;
    }
}

-(bool)connected
{
    return qControllerGW.connected();
}

-(void)disconnect
{
    @try
    {
        qControllerGW.disconnect();
    }
    @catch(...)
    {
        @throw;
    }
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

- (id<QSubscriptionDelegateObjC>)allocateSubBySourceId:(NSString *)sourceId profileSet:(QClientProfileSet)profileSet {
    if (!subscriberDelegate) return nil;
    return  [subscriberDelegate allocateSubBySourceId:sourceId profileSet:profileSet];
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

- (void) publishObject: (NSString*) quicrNamespace data: (const void *) dataPtr length: (size_t) dataLen group: (bool) groupFlag
{
    qControllerGW.publishNamedObject(std::string([quicrNamespace UTF8String]), (std::uint8_t *)dataPtr, (int)dataLen, groupFlag);
}

- (void) setSubscriptionSingleOrdered:(bool)new_value {
    qControllerGW.setSubscriptionSingleOrdered(new_value);
}

- (void) setPublicationSingleOrdered:(bool)new_value {
    qControllerGW.setPublicationSingleOrdered(new_value);
}

@end

// C++

int QControllerGW::connect(const std::string remote_address,
                           std::uint16_t remote_port,
                           std::uint16_t protocol,
                           qtransport::TransportConfig config)
{
    qController = std::make_unique<qmedia::QController>(subscriberDelegate, publisherDelegate, logger);
    if (qController == nullptr)
        return -1;

    quicr::RelayInfo::Protocol proto = quicr::RelayInfo::Protocol(protocol);
    std::string address = remote_address;
    return qController->connect(address, remote_port, proto, config);
}

bool QControllerGW::connected()
{
    if (!qController)
    {
        logger->error << "QControllerGW::connected - qController nil" << std::flush;
        return false;
    }

    return qController->connected();
}

void QControllerGW::disconnect()
{
    if (!qController)
    {
        logger->error << "QControllerGW::disconnect - qController nil" << std::flush;
        return;
    }

    qController->disconnect();
 }

void QControllerGW::updateManifest(const std::string manifest)
{
    if (qController)
    {
        qController->updateManifest(json::parse(manifest).get<qmedia::manifest::Manifest>());
    }
    else
    {
        logger->error << "QControllerGW::updateManifest - qController nil" << std::flush;
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
        logger->error << "QControllerGW::publishNamedObject - qController nil" << std::flush;
    }
}

void QControllerGW::setSubscriptionSingleOrdered(bool new_value) {
    qController->setSubscriptionSingleOrdered(new_value);
}

void QControllerGW::setPublicationSingleOrdered(bool new_value) {
    qController->setPublicationSingleOrdered(new_value);
}

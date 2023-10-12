//
//  QDelegatesObjCImpl.m
//  Decimus
//
//  Created by Scott Henning on 5/26/23.
//
#import <Foundation/Foundation.h>

#include <string>
#include <iostream>
#include "qmedia/QDelegates.hpp"
#include "quicr/quicr_common.h"
#include "QMediaDelegates.h"
#import "QControllerGWObjC.h"


#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

namespace qclient
{

// SUBSCRIPTION
QMediaSubscriptionDelegate::QMediaSubscriptionDelegate(id<QSubscriptionDelegateObjC> delegate,
                                                       const quicr::Namespace& quicrNamespace,
                                                       const std::shared_ptr<cantina::Logger>& logger)
    : qmedia::SubscriptionDelegate(quicrNamespace, logger), delegate(delegate)
{
}

int QMediaSubscriptionDelegate::prepare(const std::string& label, const std::string& qualityProfile, bool& reliable) {
    return [delegate prepare:@(label.c_str()) qualityProfile:@(qualityProfile.c_str()) reliable:&reliable];
}

int  QMediaSubscriptionDelegate::update(const std::string& label, const std::string& qualityProfile)  {
    return [delegate update:@(label.c_str()) qualityProfile:@(qualityProfile.c_str())];
}

int QMediaSubscriptionDelegate::subscribedObject(quicr::bytes&& data, std::uint32_t group, std::uint16_t object) {
    return [delegate subscribedObject:data.data() length:data.size() groupId:group objectId:object];
}


// PUBLICATION
QMediaPublicationDelegate::QMediaPublicationDelegate(id<QPublicationDelegateObjC> delegate,
                                                     const quicr::Namespace& quicrNamespace,
                                                     const std::vector<std::uint8_t>& priorities,
                                                     std::uint16_t expiry,
                                                     const std::shared_ptr<cantina::Logger>& logger)
    : qmedia::PublicationDelegate("", quicrNamespace, priorities, expiry, logger), delegate(delegate)
{
}

int QMediaPublicationDelegate::prepare(const std::string& qualityProfile, bool& reliable)  {
    return [delegate prepare:@(qualityProfile.c_str()) reliable:&reliable];
}

int QMediaPublicationDelegate::update(const std::string& qualityProfile) {
    return [delegate update:@(qualityProfile.c_str())];
}

void QMediaPublicationDelegate::publish(bool pubFlag) {
    return [delegate publish: pubFlag];
}

// SUBSCRIBER
QMediaSubsciberDelegate::QMediaSubsciberDelegate(id<QSubscriberDelegateObjC> delegate) : delegate(delegate)
{
}

std::shared_ptr<qmedia::SubscriptionDelegate> QMediaSubsciberDelegate::allocateSubByNamespace(const quicr::Namespace& quicrNamespace,
                                                                                              const std::string& qualityProfile,
                                                                                              const cantina::LoggerPointer& logger)
{
    NSString *quicrNamespaceNSString = [NSString stringWithCString:std::string(quicrNamespace).c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *qualityProfileNSString = [NSString stringWithCString:qualityProfile.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    id<QSubscriptionDelegateObjC> subscription = [delegate allocateSubByNamespace:quicrNamespaceNSString qualityProfile:qualityProfileNSString];
    return qclient::QMediaSubscriptionDelegate::create(subscription, quicrNamespace, logger);
}

int QMediaSubsciberDelegate::removeSubByNamespace(const quicr::Namespace& quicrNamespace)
{
   return 0;
}

// PUBLISHER

QMediaPublisherDelegate::QMediaPublisherDelegate(id<QPublisherDelegateObjC> delegate) : delegate(delegate)
{
}

std::shared_ptr<qmedia::PublicationDelegate> QMediaPublisherDelegate::allocatePubByNamespace(const quicr::Namespace& quicrNamespace,
                                                                                             const std::string& sourceID,
                                                                                             const std::vector<std::uint8_t>& priorities,
                                                                                             std::uint16_t expiry,
                                                                                             const std::string& qualityProfile,
                                                                                             const cantina::LoggerPointer& logger)
{
    NSString *quicrNamespaceNSString = [NSString stringWithCString:std::string(quicrNamespace).c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *quicrSourceIdNSString = [NSString stringWithCString:sourceID.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *qualityProfileNSString = [NSString stringWithCString:qualityProfile.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    id<QPublicationDelegateObjC> publication = [delegate allocatePubByNamespace:quicrNamespaceNSString sourceID:quicrSourceIdNSString qualityProfile:qualityProfileNSString];
    return qclient::QMediaPublicationDelegate::create(publication, quicrNamespace, priorities, expiry, logger);
}

int QMediaPublisherDelegate::removePubByNamespace(const quicr::Namespace& quicrNamespace)
{
   return 0;
}

};

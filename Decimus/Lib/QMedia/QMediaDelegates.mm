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

// Helpers.
static QClientProfile fromProfile(qmedia::manifest::Profile profile)
{
    QClientProfile clientProfile;
    clientProfile.qualityProfile = @(profile.qualityProfile.c_str());
    clientProfile.quicrNamespace = @(std::string(UrlEncoder().EncodeUrl(profile.quicrNamespaceUrl)).c_str());
    clientProfile.prioritiesCount = profile.priorities.size();
    clientProfile.priorities = &profile.priorities[0];
    return clientProfile;
}

static QClientProfileSet fromProfileSet(const qmedia::manifest::ProfileSet& profileSet)
{
    QClientProfileSet clientProfileSet;
    clientProfileSet.type = @(profileSet.type.c_str());
    clientProfileSet.profilesCount = profileSet.profiles.size();
    clientProfileSet.profiles = new qmedia::manifest::Profile[clientProfileSet.profilesCount];
    for (size_t profileIndex = 0; profileIndex <= clientProfileSet.profilesCount; profileIndex++)
    {
        clientProfileSet.profiles[profileIndex] = fromProfile(profileSet.profiles[profileIndex]);
    }
    return clientProfileSet;
}

// SUBSCRIPTION
QMediaSubscriptionDelegate::QMediaSubscriptionDelegate(id<QSubscriptionDelegateObjC> delegate, const std::string& sourceId) :
    delegate(delegate), sourceId(sourceId)
{
}

int QMediaSubscriptionDelegate::prepare(const std::string& sourceId,  const std::string& label, const qmedia::manifest::ProfileSet& profileSet, bool& reliable) {
    QClientProfileSet clientProfileSet = fromProfileSet(profileSet);
    return [delegate prepare: @(sourceId.c_str()) label:@(label.c_str()) profileSet:clientProfileSet reliable:&reliable];
}

int  QMediaSubscriptionDelegate::update(const std::string& sourceId,  const std::string& label, const qmedia::manifest::ProfileSet& profileSet)  {
    QClientProfileSet clientProfileSet = fromProfileSet(profileSet);
    return [delegate update:@(sourceId.c_str()) label:@(label.c_str()) profileSet:clientProfileSet];
}
/*
quicr::Namespace QMediaSubscriptionDelegate::getNamespace() {
    return quicrNamespace;
}*/

int QMediaSubscriptionDelegate::subscribedObject(const quicr::Name& name, quicr::bytes&& data, std::uint32_t group, std::uint16_t object) {
    return [delegate subscribedObject:@(std::string(name).c_str()) data:data.data() length:data.size() groupId:group objectId:object];
}


// PUBLICATION
QMediaPublicationDelegate::QMediaPublicationDelegate(id<QPublicationDelegateObjC> delegate, const quicr::Namespace& quicrNamespace)
    : delegate(delegate), quicrNamespace(quicrNamespace)
{
}

int QMediaPublicationDelegate::prepare(const std::string& sourceId,  const std::string& qualityProfile, bool& reliable)  {
    return [delegate prepare:@(sourceId.c_str()) qualityProfile:@(qualityProfile.c_str()) reliable:&reliable];
}
int QMediaPublicationDelegate::update(const std::string& sourceId, const std::string& qualityProfile) {
    return [delegate update:@(sourceId.c_str()) qualityProfile:@(qualityProfile.c_str())];
}
/*
quicr::Namespace QMediaPublicationDelegate::getNamespace()  {
    return;
}*/

void QMediaPublicationDelegate::publish(bool pubFlag) {
    return [delegate publish: pubFlag];
}

// SUBSCRIBER
QMediaSubsciberDelegate::QMediaSubsciberDelegate(id<QSubscriberDelegateObjC> delegate) : delegate(delegate)
{
}

std::shared_ptr<qmedia::QSubscriptionDelegate> QMediaSubsciberDelegate::allocateSubBySourceId(const std::string& sourceId, const qmedia::manifest::ProfileSet& profileSet)
{
    NSString *sourceIdNSString = [NSString stringWithCString:sourceId.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    QClientProfileSet qClientProfileSet = fromProfileSet(profileSet);
    id<QSubscriptionDelegateObjC> subscription = [delegate allocateSubBySourceId:@(sourceId.c_str()) profileSet:qClientProfileSet];
    return std::make_shared<qclient::QMediaSubscriptionDelegate>(subscription, sourceId);
}

int QMediaSubsciberDelegate::removeSubBySourceId(const std::string& sourceId)
{
   return 0;
}

// PUBLISHER

QMediaPublisherDelegate::QMediaPublisherDelegate(id<QPublisherDelegateObjC> delegate) : delegate(delegate)
{
}

std::shared_ptr<qmedia::QPublicationDelegate> QMediaPublisherDelegate::allocatePubByNamespace(const quicr::Namespace& quicrNamespace, const std::string& sourceID, const std::string& qualityProfile)
{
    NSString *quicrNamespaceNSString = [NSString stringWithCString:std::string(quicrNamespace).c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *quicrSourceIdNSString = [NSString stringWithCString:sourceID.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *qualityProfileNSString = [NSString stringWithCString:qualityProfile.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    id<QPublicationDelegateObjC> publication = [delegate allocatePubByNamespace:quicrNamespaceNSString sourceID:quicrSourceIdNSString qualityProfile:qualityProfileNSString];
    return std::make_shared<qclient::QMediaPublicationDelegate>(publication, quicrNamespace);
}

int QMediaPublisherDelegate::removePubByNamespace(const quicr::Namespace& quicrNamespace)
{
   return 0;
}

};

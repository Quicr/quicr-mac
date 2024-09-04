// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

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
    clientProfile.qualityProfile = strdup(profile.qualityProfile.c_str());
    clientProfile.quicrNamespace = strdup(std::string(profile.quicrNamespace).c_str());
    clientProfile.prioritiesCount = profile.priorities.size();
    clientProfile.priorities = profile.priorities.data();
    clientProfile.expiryCount = profile.expiry.size();
    clientProfile.expiry = profile.expiry.data();
    return clientProfile;
}

static void deleteProfile(QClientProfile profile)
{
    free((void*)profile.qualityProfile);
    free((void*)profile.quicrNamespace);
}

static QClientProfileSet fromProfileSet(const qmedia::manifest::ProfileSet& profileSet)
{
    QClientProfileSet clientProfileSet;
    clientProfileSet.type = profileSet.type.c_str();
    clientProfileSet.profilesCount = profileSet.profiles.size();
    clientProfileSet.profiles = new QClientProfile[clientProfileSet.profilesCount];
    for (size_t profileIndex = 0; profileIndex < clientProfileSet.profilesCount; profileIndex++)
    {
        clientProfileSet.profiles[profileIndex] = fromProfile(profileSet.profiles[profileIndex]);
    }
    return clientProfileSet;
}

static void deleteProfileSet(QClientProfileSet profileSet)
{
    for (size_t profileIndex = 0; profileIndex < profileSet.profilesCount; profileIndex++)
    {
        deleteProfile(profileSet.profiles[profileIndex]);
    }
    delete[] profileSet.profiles;
}

// SUBSCRIPTION
QMediaSubscriptionDelegate::QMediaSubscriptionDelegate(id<QSubscriptionDelegateObjC> delegate, const std::string& sourceId) :
    delegate(delegate), sourceId(sourceId)
{
}

int QMediaSubscriptionDelegate::prepare(const std::string& sourceId,  const std::string& label, const qmedia::manifest::ProfileSet& profileSet, quicr::TransportMode& transportMode) {
    QClientProfileSet clientProfileSet = fromProfileSet(profileSet);
    TransportMode mode = TransportModeUnreliable;
    const int prepareResult = [delegate prepare: @(sourceId.c_str()) label:@(label.c_str()) profileSet:clientProfileSet transportMode:&mode];
    transportMode = static_cast<quicr::TransportMode>(static_cast<uint8_t>(mode));
    deleteProfileSet(clientProfileSet);
    return prepareResult;
}

int  QMediaSubscriptionDelegate::update(const std::string& sourceId,  const std::string& label, const qmedia::manifest::ProfileSet& profileSet)  {
    QClientProfileSet clientProfileSet = fromProfileSet(profileSet);
    const int updateResult = [delegate update:@(sourceId.c_str()) label:@(label.c_str()) profileSet:clientProfileSet];
    deleteProfileSet(clientProfileSet);
    return updateResult;
}
/*
quicr::Namespace QMediaSubscriptionDelegate::getNamespace() {
    return quicrNamespace;
}*/

int QMediaSubscriptionDelegate::subscribedObject(const quicr::Namespace& quicrNamespace, quicr::bytes&& data, std::uint32_t group, std::uint16_t object) {
    return [delegate subscribedObject:@(std::string(quicrNamespace).c_str()) data:data.data() length:data.size() groupId:group objectId:object];
}


// PUBLICATION
QMediaPublicationDelegate::QMediaPublicationDelegate(id<QPublicationDelegateObjC> delegate, const quicr::Namespace& quicrNamespace)
    : delegate(delegate), quicrNamespace(quicrNamespace)
{
}

int QMediaPublicationDelegate::prepare(const std::string& sourceId,  const std::string& qualityProfile, quicr::TransportMode& transportMode)  {
    TransportMode mode = TransportModeUnreliable;
    const int result = [delegate prepare:@(sourceId.c_str()) qualityProfile:@(qualityProfile.c_str()) transportMode:&mode];
    transportMode = static_cast<quicr::TransportMode>(static_cast<uint8_t>(mode));
    return result;
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
    id<QSubscriptionDelegateObjC> subscription = [delegate allocateSubBySourceId:sourceIdNSString profileSet:qClientProfileSet];
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

std::shared_ptr<qmedia::QPublicationDelegate> QMediaPublisherDelegate::allocatePubByNamespace(const quicr::Namespace& quicrNamespace, const std::string& sourceID, const std::string& qualityProfile, const std::string& appTag)
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

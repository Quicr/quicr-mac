//
//  QDelegatesImpl.h
//  Decimus
//
//  Created by Scott Henning on 5/26/23.
//

#ifndef QMediaDelegates_h
#define QMediaDelegates_h

#include <string>
#include <quicr/quicr_common.h>
#include "qmedia/QDelegates.hpp"

#import "QControllerGWObjC.h"
#import "QDelegatesObjC.h"

namespace qclient
{
class QMediaSubscriptionDelegate : public qmedia::QSubscriptionDelegate
{
public:
    QMediaSubscriptionDelegate(id<QSubscriptionDelegateObjC> delegate, const quicr::Namespace& quicrNamespace);
public:
    int prepare(const std::string& sourceId,  const std::string& label, const std::string& qualityProfile, bool& reliable) override;
    int update(const std::string& sourceId,  const std::string& label, const std::string& qualityProfile) override;
    //quicr::Namespace getNamespace() override;
    int subscribedObject(quicr::bytes&& data, std::uint32_t groupId, std::uint16_t objectId);

private:
    quicr::Namespace quicrNamespace;
    id<QSubscriptionDelegateObjC> delegate;
};

class QMediaPublicationDelegate : public qmedia::QPublicationDelegate
{
public:
    QMediaPublicationDelegate(id<QPublicationDelegateObjC> delegate, const quicr::Namespace& quicrNamespace);
public:
    int prepare(const std::string& sourceId,  const std::string& qualityProfile, bool &reliable);
    int update(const std::string& sourceId, const std::string& qualityProfile);
    void publish(bool pubFlag);
    //quicr::Namespace getNamespace();
private:
    quicr::Namespace quicrNamespace;
    id<QPublicationDelegateObjC> delegate;
};

class QMediaSubsciberDelegate : public qmedia::QSubscriberDelegate
{
public:
    QMediaSubsciberDelegate(id<QSubscriberDelegateObjC> delegate);
    std::shared_ptr<qmedia::QSubscriptionDelegate> allocateSubByNamespace(const quicr::Namespace& quicrNamespace, const std::string& qualityProfile);
    int removeSubByNamespace(const quicr::Namespace& quicrNamespace);
private:
    id<QSubscriberDelegateObjC> delegate;
};

class QMediaPublisherDelegate : public qmedia::QPublisherDelegate
{
public:
    QMediaPublisherDelegate(id<QPublisherDelegateObjC> delegate);
    std::shared_ptr<qmedia::QPublicationDelegate> allocatePubByNamespace(const quicr::Namespace& quicrNamespace, const std::string& sourceID, const std::string& qualityProfile);
    int removePubByNamespace(const quicr::Namespace& quicrNamespace);
private:
    id<QPublisherDelegateObjC> delegate;
};
}

#endif /* QMediaDelegates_h */

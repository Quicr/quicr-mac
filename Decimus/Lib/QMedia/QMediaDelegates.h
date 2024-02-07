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
    QMediaSubscriptionDelegate(id<QSubscriptionDelegateObjC> delegate, const SourceId& sourceId);
public:
    int prepare(const std::string& sourceId,  const std::string& label, const qmedia::manifest::ProfileSet& profileSet, bool& reliable) override;
    int update(const std::string& sourceId,  const std::string& label, const qmedia::manifest::ProfileSet& profileSet) override;
    int subscribedObject(const quicr::Namespace& quicrNamespace, quicr::bytes&& data, std::uint32_t groupId, std::uint16_t objectId) override;
private:
    std::string sourceId;
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

private:
    quicr::Namespace quicrNamespace;
    id<QPublicationDelegateObjC> delegate;
};

class QMediaSubsciberDelegate : public qmedia::QSubscriberDelegate
{
public:
    QMediaSubsciberDelegate(id<QSubscriberDelegateObjC> delegate);
    std::shared_ptr<qmedia::QSubscriptionDelegate> allocateSubBySourceId(const std::string& sourceId, const qmedia::manifest::ProfileSet& qualityProfile);
    int removeSubBySourceId(const std::string& sourceId);
private:
    id<QSubscriberDelegateObjC> delegate;
};

class QMediaPublisherDelegate : public qmedia::QPublisherDelegate
{
public:
    QMediaPublisherDelegate(id<QPublisherDelegateObjC> delegate);
    std::shared_ptr<qmedia::QPublicationDelegate> allocatePubByNamespace(const quicr::Namespace& quicrNamespace, const std::string& sourceID, const std::string& qualityProfile, const std::string& appTag);
    int removePubByNamespace(const quicr::Namespace& quicrNamespace);
private:
    id<QPublisherDelegateObjC> delegate;
};
}

#endif /* QMediaDelegates_h */

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
class QMediaSubscriptionDelegate : public qmedia::SubscriptionDelegate
{
    QMediaSubscriptionDelegate(id<QSubscriptionDelegateObjC> delegate,
                               const quicr::Namespace& quicrNamespace,
                               const std::shared_ptr<cantina::Logger>& logger);
 
public:
    static inline auto create(id<QSubscriptionDelegateObjC> delegate,
                              const quicr::Namespace& quicrNamespace,
                              const std::shared_ptr<cantina::Logger>& logger)
    {
        return std::shared_ptr<QMediaSubscriptionDelegate>(new QMediaSubscriptionDelegate(delegate,
                                                                                          quicrNamespace,
                                                                                          logger));
    }

public:
    int prepare(const std::string& label, const std::string& qualityProfile, bool& reliable) override;
    int update(const std::string& label, const std::string& qualityProfile) override;
    int subscribedObject(quicr::bytes&& data, std::uint32_t groupId, std::uint16_t objectId) override;

private:
    quicr::Namespace quicrNamespace;
    id<QSubscriptionDelegateObjC> delegate;
};

class QMediaPublicationDelegate : public qmedia::PublicationDelegate
{
    QMediaPublicationDelegate(id<QPublicationDelegateObjC> delegate,
                              const quicr::Namespace& quicrNamespace,
                              const std::vector<std::uint8_t>& priorities,
                              std::uint16_t expiry,
                              const std::shared_ptr<cantina::Logger>& logger);

public:
    static inline auto create(id<QPublicationDelegateObjC> delegate,
                              const quicr::Namespace& quicrNamespace,
                              const std::vector<std::uint8_t>& priorities,
                              std::uint16_t expiry,
                              const std::shared_ptr<cantina::Logger>& logger)
    {
        return std::shared_ptr<QMediaPublicationDelegate>(new QMediaPublicationDelegate(delegate,
                                                                                        quicrNamespace,
                                                                                        priorities,
                                                                                        expiry,
                                                                                        logger));
    }

public:
    int prepare(const std::string& qualityProfile, bool &reliable);
    int update(const std::string& qualityProfile);
    void publish(bool pubFlag);

private:
    quicr::Namespace quicrNamespace;
    id<QPublicationDelegateObjC> delegate;
};

class QMediaSubsciberDelegate : public qmedia::SubscriberDelegate
{
public:
    QMediaSubsciberDelegate(id<QSubscriberDelegateObjC> delegate);
    std::shared_ptr<qmedia::SubscriptionDelegate> allocateSubByNamespace(const quicr::Namespace& quicrNamespace,
                                                                         const std::string& qualityProfile,
                                                                         const cantina::LoggerPointer& logger);
    int removeSubByNamespace(const quicr::Namespace& quicrNamespace);

private:
    id<QSubscriberDelegateObjC> delegate;
};

class QMediaPublisherDelegate : public qmedia::PublisherDelegate
{
public:
    QMediaPublisherDelegate(id<QPublisherDelegateObjC> delegate);
    std::shared_ptr<qmedia::PublicationDelegate> allocatePubByNamespace(const quicr::Namespace& quicrNamespace,
                                                                        const std::string& sourceID,
                                                                        const std::vector<std::uint8_t>& priorities,
                                                                        std::uint16_t expiry,
                                                                        const std::string& qualityProfile,
                                                                        const cantina::LoggerPointer& logger);
    int removePubByNamespace(const quicr::Namespace& quicrNamespace);
private:
    id<QPublisherDelegateObjC> delegate;
};
}

#endif /* QMediaDelegates_h */

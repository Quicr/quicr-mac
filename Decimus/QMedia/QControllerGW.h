//
//  QControllerGW.h
//  Decimus
//
//  Created by Scott Henning on 2/13/23.
//
#ifndef QControllerGW_h
#define QControllerGW_h

#include "qmedia/QController.hpp"
#include "qmedia/QDelegates.hpp"
#include "QDelegatesObjC.h"
#import "QControllerGWObjC.h"

@class QControllerGWObjC;

class QControllerGW {
public:
    
    //QControllerGW(QControllerGWObjC  *objcSelf);
    QControllerGW();
    ~QControllerGW();

    int connect(const std::string remote_address,
                 std::uint16_t remote_port,
                 std::uint16_t protocol);
    
    void updateManifest(const std::string manifest);
       
    void setSubscriberDelegate(id<QSubscriberDelegateObjC>);
    void setPublisherDelegate(id<QPublisherDelegateObjC>);
    
private:
    std::unique_ptr<qmedia::QController> qController;
    std::shared_ptr<qmedia::QSubscriberDelegate> subscriberDelegate;
    std::shared_ptr<qmedia::QPublisherDelegate> publisherDelegate;
};

#endif /* QMediaClient */

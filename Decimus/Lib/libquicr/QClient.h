#ifndef QClient_h
#define QClient_h

#import "QClientCallbacks.h"

#include "moq/client.h"
#include "moq/config.h"

class QClient : public moq::Client
{
public:
    QClient(moq::ClientConfig config);
    ~QClient();

    void StatusChanged(Status status) override;
    void ServerSetupReceived(const moq::ServerSetupAttributes& serverSetupAttributes) override;
    
    
    void SetCallbacks(id<QClientCallbacks> callbacks);
private:
     id<QClientCallbacks> __weak _callbacks;
};


#endif /* QClient_h */

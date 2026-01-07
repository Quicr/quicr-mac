// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#import "MoxygenClientObjC.h"

#include <moxygen/MoQClient.h>
#include <moxygen/MoQFramer.h>
#include <moxygen/MoQConsumers.h>
#include <moxygen/Subscriber.h>
#include <moxygen/events/MoQFollyExecutorImpl.h>
#include <moxygen/util/InsecureVerifierDangerousDoNotUseInProduction.h>
#include <folly/init/Init.h>
#include <folly/io/async/EventBase.h>
#include <folly/coro/BlockingWait.h>
#include <folly/Singleton.h>
#include <proxygen/lib/utils/URL.h>
#include <quic/QuicException.h>
#include <glog/logging.h>
#include <memory>
#include <thread>

namespace {

class FollyInitializer {
public:
    static void ensureInitialized() {
        static FollyInitializer instance;
    }

private:
    std::unique_ptr<folly::Init> init_;

    FollyInitializer() {
        FLAGS_logtostderr = true;
        FLAGS_minloglevel = 4;
        FLAGS_v = -1;

        int argc = 1;
        char programName[] = "Decimus";
        char* argv[] = {programName, nullptr};
        char** argvPtr = argv;
        init_ = std::make_unique<folly::Init>(&argc, &argvPtr, false);

        folly::SingletonVault::singleton()->registrationComplete();
    }
};

// SubgroupConsumer that forwards data to Obj-C callback
class ObjCSubgroupConsumer : public moxygen::SubgroupConsumer {
public:
    ObjCSubgroupConsumer(uint64_t groupId, uint64_t subgroupId,
                         __weak id<MoxygenTrackCallback> callback)
        : groupId_(groupId), subgroupId_(subgroupId), callback_(callback) {}

    folly::Expected<folly::Unit, moxygen::MoQPublishError> object(
        uint64_t objectID,
        moxygen::Payload payload,
        moxygen::Extensions extensions = moxygen::noExtensions(),
        bool finSubgroup = false) override {

        id<MoxygenTrackCallback> strongCallback = callback_;
        if (strongCallback && payload) {
            NSData* data = [NSData dataWithBytes:payload->data()
                                          length:payload->computeChainDataLength()];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongCallback onObjectReceived:groupId_
                                      subgroupId:subgroupId_
                                        objectId:objectID
                                            data:data];
            });
        }
        return folly::unit;
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> objectNotExists(
        uint64_t objectID, bool finSubgroup = false) override {
        return folly::unit;
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> beginObject(
        uint64_t objectID, uint64_t length, moxygen::Payload initialPayload,
        moxygen::Extensions extensions = moxygen::noExtensions()) override {
        // For simplicity, treat beginObject + payload as single object
        if (initialPayload) {
            return object(objectID, std::move(initialPayload), std::move(extensions), false);
        }
        return folly::unit;
    }

    folly::Expected<moxygen::ObjectPublishStatus, moxygen::MoQPublishError> objectPayload(
        moxygen::Payload payload, bool finSubgroup = false) override {
        // Streaming object payload - we simplified this for now
        return moxygen::ObjectPublishStatus::DONE;
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> endOfGroup(
        uint64_t endOfGroupObjectID) override {
        return folly::unit;
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> endOfTrackAndGroup(
        uint64_t endOfTrackObjectID) override {
        return folly::unit;
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> endOfSubgroup() override {
        return folly::unit;
    }

    void reset(moxygen::ResetStreamErrorCode error) override {}

private:
    uint64_t groupId_;
    uint64_t subgroupId_;
    __weak id<MoxygenTrackCallback> callback_;
};

// TrackConsumer that forwards to Obj-C callback
class ObjCTrackConsumer : public moxygen::TrackConsumer {
public:
    explicit ObjCTrackConsumer(__weak id<MoxygenTrackCallback> callback)
        : callback_(callback) {}

    folly::Expected<folly::Unit, moxygen::MoQPublishError> setTrackAlias(
        moxygen::TrackAlias alias) override {
        trackAlias_ = alias;
        return folly::unit;
    }

    folly::Expected<std::shared_ptr<moxygen::SubgroupConsumer>, moxygen::MoQPublishError>
    beginSubgroup(uint64_t groupID, uint64_t subgroupID, moxygen::Priority priority) override {
        return std::make_shared<ObjCSubgroupConsumer>(groupID, subgroupID, callback_);
    }

    folly::Expected<folly::SemiFuture<folly::Unit>, moxygen::MoQPublishError>
    awaitStreamCredit() override {
        return folly::makeSemiFuture(folly::unit);
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> objectStream(
        const moxygen::ObjectHeader& header, moxygen::Payload payload) override {
        id<MoxygenTrackCallback> strongCallback = callback_;
        if (strongCallback && payload) {
            NSData* data = [NSData dataWithBytes:payload->data()
                                          length:payload->computeChainDataLength()];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongCallback onObjectReceived:header.group
                                      subgroupId:header.subgroup
                                        objectId:header.id
                                            data:data];
            });
        }
        return folly::unit;
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> datagram(
        const moxygen::ObjectHeader& header, moxygen::Payload payload) override {
        return objectStream(header, std::move(payload));
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError>
    groupNotExists(uint64_t groupID, uint64_t subgroup, moxygen::Priority pri) override {
        return folly::unit;
    }

    folly::Expected<folly::Unit, moxygen::MoQPublishError> subscribeDone(
        moxygen::SubscribeDone subDone) override {
        id<MoxygenTrackCallback> strongCallback = callback_;
        if (strongCallback) {
            NSString* reason = [NSString stringWithUTF8String:subDone.reasonPhrase.c_str()];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongCallback onSubscribeStatus:MoxygenSubscribeStatusDone message:reason];
            });
        }
        return folly::unit;
    }

private:
    __weak id<MoxygenTrackCallback> callback_;
    folly::Optional<moxygen::TrackAlias> trackAlias_;
};

} // namespace

#pragma mark - MoxygenObjectHeader

@implementation MoxygenObjectHeader
- (instancetype)init {
    self = [super init];
    if (self) {
        _groupId = 0;
        _subgroupId = 0;
        _objectId = 0;
        _priority = 128;
    }
    return self;
}
@end

#pragma mark - MoxygenSubscribeRequest

@implementation MoxygenSubscribeRequest
- (instancetype)init {
    self = [super init];
    if (self) {
        _trackNamespace = @[];
        _trackName = @"";
        _priority = 128;
        _groupOrder = MoxygenGroupOrderDefault;
    }
    return self;
}
@end

#pragma mark - MoxygenClientConfig

@implementation MoxygenClientConfig

- (instancetype)init {
    self = [super init];
    if (self) {
        _connectURL = @"https://127.0.0.1:4433/moq";
        _connectTimeout = 5.0;
    }
    return self;
}

@end

#pragma mark - MoxygenPublisher

@interface MoxygenPublisher () {
    std::shared_ptr<moxygen::TrackConsumer> _trackConsumer;
    std::shared_ptr<moxygen::SubgroupConsumer> _currentSubgroup;
    uint64_t _currentGroupId;
    uint64_t _currentSubgroupId;
    folly::EventBase* _eventBase;
}
@end

@implementation MoxygenPublisher

- (instancetype)initWithTrackConsumer:(std::shared_ptr<moxygen::TrackConsumer>)consumer
                            eventBase:(folly::EventBase*)eventBase {
    self = [super init];
    if (self) {
        _trackConsumer = consumer;
        _eventBase = eventBase;
        _currentGroupId = UINT64_MAX;
        _currentSubgroupId = UINT64_MAX;
    }
    return self;
}

- (BOOL)publishObject:(MoxygenObjectHeader *)header data:(NSData *)data {
    if (!_trackConsumer) {
        return NO;
    }

    bool success = false;

    _eventBase->runInEventBaseThreadAndWait([self, header, data, &success]() {
        // Check if we need a new subgroup
        if (header.groupId != _currentGroupId || header.subgroupId != _currentSubgroupId) {
            auto result = _trackConsumer->beginSubgroup(
                header.groupId, header.subgroupId, header.priority);
            if (result.hasError()) {
                return;
            }
            _currentSubgroup = result.value();
            _currentGroupId = header.groupId;
            _currentSubgroupId = header.subgroupId;
        }

        if (!_currentSubgroup) {
            return;
        }

        // Create payload from NSData
        auto payload = folly::IOBuf::copyBuffer(data.bytes, data.length);

        auto objResult = _currentSubgroup->object(
            header.objectId,
            std::move(payload),
            moxygen::noExtensions(),
            false);

        success = !objResult.hasError();
    });

    return success ? YES : NO;
}

- (void)close {
    if (_trackConsumer && _eventBase) {
        _eventBase->runInEventBaseThreadAndWait([self]() {
            if (_currentSubgroup) {
                _currentSubgroup->endOfSubgroup();
                _currentSubgroup.reset();
            }
            moxygen::SubscribeDone done;
            done.statusCode = moxygen::SubscribeDoneStatusCode::SUBSCRIPTION_ENDED;
            _trackConsumer->subscribeDone(done);
            _trackConsumer.reset();
        });
    }
}

- (void)dealloc {
    [self close];
}

@end

#pragma mark - MoxygenClientObjC

@interface MoxygenClientObjC () {
    std::unique_ptr<folly::EventBase> _eventBase;
    std::shared_ptr<moxygen::MoQFollyExecutorImpl> _executor;
    std::unique_ptr<moxygen::MoQClient> _client;
    std::unique_ptr<std::thread> _eventThread;
    MoxygenClientConfig *_config;
    std::atomic<bool> _running;
    quic::TransportSettings _transportSettings;
    std::vector<std::string> _alpns;
}

@property (nonatomic, readwrite) MoxygenConnectionStatus status;
@property (nonatomic, weak) id<MoxygenClientCallbacks> callbacks;

@end

@implementation MoxygenClientObjC

- (instancetype)initWithConfig:(MoxygenClientConfig *)config {
    self = [super init];
    if (self) {
        @try {
            FollyInitializer::ensureInitialized();

            _config = config;
            _status = MoxygenConnectionStatusDisconnected;
            _running = false;

            _eventBase = std::make_unique<folly::EventBase>();
            _executor = std::make_shared<moxygen::MoQFollyExecutorImpl>(_eventBase.get());

            std::string urlStr = std::string([config.connectURL UTF8String]);
            proxygen::URL parsedUrl(urlStr);

            auto verifier = std::make_shared<moxygen::test::InsecureVerifierDangerousDoNotUseInProduction>();
            _client = std::make_unique<moxygen::MoQClient>(_executor, std::move(parsedUrl), verifier);
            _alpns = moxygen::getDefaultMoqtProtocols(false);
        } @catch (NSException *exception) {
            NSLog(@"MoxygenClient: Init failed: %@", exception.reason);
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
}

- (void)setCallbacks:(id<MoxygenClientCallbacks>)callbacks {
    _callbacks = callbacks;
}

- (void)connect {
    if (_status == MoxygenConnectionStatusConnecting || _status == MoxygenConnectionStatusConnected) {
        return;
    }

    self.status = MoxygenConnectionStatusConnecting;
    [self notifyStatusChanged:MoxygenConnectionStatusConnecting];

    _running = true;

    auto connectTimeout = std::chrono::milliseconds(static_cast<int64_t>(_config.connectTimeout * 1000));

    MoxygenClientObjC* __weak weakSelf = self;

    _eventThread = std::make_unique<std::thread>([weakSelf, connectTimeout]() {
        MoxygenClientObjC* selfPtr = weakSelf;
        if (!selfPtr) return;

        selfPtr->_eventBase->runInEventBaseThread([weakSelf, connectTimeout]() {
            MoxygenClientObjC* selfPtr = weakSelf;
            if (!selfPtr) return;

            selfPtr->_transportSettings.datagramConfig.enabled = true;

            selfPtr->_client->setupMoQSession(
                connectTimeout,
                connectTimeout,
                nullptr,
                nullptr,
                selfPtr->_transportSettings,
                selfPtr->_alpns
            ).scheduleOn(selfPtr->_executor.get()).start(
                [weakSelf](folly::Try<void>&& result) {
                    MoxygenClientObjC* selfPtr = weakSelf;
                    if (!selfPtr) return;

                    if (result.hasException()) {
                        std::string errorMsg;
                        try {
                            result.throwUnlessValue();
                        } catch (const std::exception& e) {
                            errorMsg = e.what();
                        } catch (...) {
                            errorMsg = "Unknown error";
                        }

                        selfPtr->_eventBase->terminateLoopSoon();

                        NSString* errorStr = [NSString stringWithUTF8String:errorMsg.c_str()];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            MoxygenClientObjC* strongSelf = weakSelf;
                            if (!strongSelf) return;
                            strongSelf.status = MoxygenConnectionStatusFailed;
                            [strongSelf notifyStatusChanged:MoxygenConnectionStatusFailed];
                            [strongSelf notifyError:errorStr];
                        });
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            MoxygenClientObjC* strongSelf = weakSelf;
                            if (!strongSelf) return;
                            strongSelf.status = MoxygenConnectionStatusConnected;
                            [strongSelf notifyStatusChanged:MoxygenConnectionStatusConnected];
                        });
                    }
                }
            );
        });

        selfPtr->_eventBase->loopForever();
    });
}

- (void)disconnect {
    if (_status == MoxygenConnectionStatusDisconnected) {
        return;
    }

    if (_client && _client->moqSession_) {
        _eventBase->runInEventBaseThreadAndWait([self]() {
            self->_client->moqSession_->close(moxygen::SessionCloseErrorCode::NO_ERROR);
        });
    }

    _eventBase->terminateLoopSoon();

    if (_eventThread && _eventThread->joinable()) {
        _eventThread->join();
    }
    _eventThread.reset();

    self.status = MoxygenConnectionStatusDisconnected;
    [self notifyStatusChanged:MoxygenConnectionStatusDisconnected];
}

- (BOOL)subscribeWithRequest:(MoxygenSubscribeRequest *)request
                    callback:(id<MoxygenTrackCallback>)callback {
    if (_status != MoxygenConnectionStatusConnected || !_client || !_client->moqSession_) {
        return NO;
    }

    // Build FullTrackName from request
    std::vector<std::string> ns;
    for (NSString* item in request.trackNamespace) {
        ns.push_back([item UTF8String]);
    }
    moxygen::FullTrackName fullTrackName;
    fullTrackName.trackNamespace = moxygen::TrackNamespace(std::move(ns));
    fullTrackName.trackName = [request.trackName UTF8String];

    // Create TrackConsumer
    auto trackConsumer = std::make_shared<ObjCTrackConsumer>(callback);

    // Build SubscribeRequest
    auto subRequest = moxygen::SubscribeRequest::make(
        fullTrackName,
        request.priority,
        static_cast<moxygen::GroupOrder>(request.groupOrder),
        true,  // forward
        moxygen::LocationType::LargestGroup
    );

    MoxygenClientObjC* __weak weakSelf = self;
    __weak id<MoxygenTrackCallback> weakCallback = callback;

    _eventBase->runInEventBaseThread([weakSelf, weakCallback, subRequest = std::move(subRequest),
                                      trackConsumer]() mutable {
        MoxygenClientObjC* selfPtr = weakSelf;
        if (!selfPtr || !selfPtr->_client || !selfPtr->_client->moqSession_) {
            return;
        }

        selfPtr->_client->moqSession_->subscribe(std::move(subRequest), trackConsumer)
            .scheduleOn(selfPtr->_executor.get())
            .start([weakCallback](folly::Try<moxygen::Publisher::SubscribeResult>&& result) {
                id<MoxygenTrackCallback> strongCallback = weakCallback;
                if (!strongCallback) return;

                if (result.hasException()) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [strongCallback onSubscribeStatus:MoxygenSubscribeStatusError
                                                  message:@"Subscribe failed"];
                    });
                } else {
                    auto& subResult = result.value();
                    if (subResult.hasError()) {
                        NSString* msg = [NSString stringWithUTF8String:
                            subResult.error().reasonPhrase.c_str()];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [strongCallback onSubscribeStatus:MoxygenSubscribeStatusError
                                                      message:msg];
                        });
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [strongCallback onSubscribeStatus:MoxygenSubscribeStatusOk
                                                      message:nil];
                        });
                    }
                }
            });
    });

    return YES;
}

- (BOOL)announceNamespace:(NSArray<NSString *> *)trackNamespace {
    // Announce is typically handled differently in moxygen (server-side)
    // For now, this is a placeholder that could be implemented if needed
    // The publish flow uses the Subscriber interface which doesn't require announce
    NSLog(@"MoxygenClient: announceNamespace not yet implemented");
    return YES;
}

- (MoxygenPublisher *)createPublisherWithNamespace:(NSArray<NSString *> *)trackNamespace
                                         trackName:(NSString *)trackName
                                        groupOrder:(MoxygenGroupOrder)groupOrder {
    if (_status != MoxygenConnectionStatusConnected || !_client || !_client->moqSession_) {
        return nil;
    }

    // Build FullTrackName
    std::vector<std::string> ns;
    for (NSString* item in trackNamespace) {
        ns.push_back([item UTF8String]);
    }
    moxygen::FullTrackName fullTrackName;
    fullTrackName.trackNamespace = moxygen::TrackNamespace(std::move(ns));
    fullTrackName.trackName = [trackName UTF8String];

    // Build PublishRequest
    moxygen::PublishRequest pubRequest;
    pubRequest.fullTrackName = fullTrackName;
    pubRequest.groupOrder = static_cast<moxygen::GroupOrder>(groupOrder);

    std::shared_ptr<moxygen::TrackConsumer> trackConsumer;
    bool success = false;

    _eventBase->runInEventBaseThreadAndWait([self, pubRequest = std::move(pubRequest),
                                              &trackConsumer, &success]() mutable {
        if (!self->_client || !self->_client->moqSession_) {
            return;
        }

        auto result = self->_client->moqSession_->publish(std::move(pubRequest), nullptr);
        if (result.hasValue() && result.value().consumer) {
            trackConsumer = result.value().consumer;
            success = true;
        }
    });

    if (!success || !trackConsumer) {
        return nil;
    }

    return [[MoxygenPublisher alloc] initWithTrackConsumer:trackConsumer
                                                eventBase:_eventBase.get()];
}

- (void)notifyStatusChanged:(MoxygenConnectionStatus)status {
    id<MoxygenClientCallbacks> callbacks = _callbacks;
    if (callbacks) {
        [callbacks onStatusChanged:status];
    }
}

- (void)notifyError:(NSString *)error {
    id<MoxygenClientCallbacks> callbacks = _callbacks;
    if (callbacks) {
        [callbacks onError:error];
    }
}

@end

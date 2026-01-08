// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#import "MoxygenClientObjC.h"

#include <moxygen/MoQClient.h>
#include <moxygen/MoQFramer.h>
#include <moxygen/MoQConsumers.h>
#include <moxygen/MoQRelaySession.h>
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
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <mach/mach_time.h>

// Forward declaration for Obj-C class used in C++ code
@class MoxygenClientObjC;

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

// Convert moxygen Extensions to NSDictionary format matching libquicr's HeaderExtensions
static NSDictionary<NSNumber*, NSArray<NSData*>*>* convertExtensions(
    const std::vector<moxygen::Extension>& extensions) {
    if (extensions.empty()) {
        return nil;
    }

    NSMutableDictionary<NSNumber*, NSMutableArray<NSData*>*>* result = [NSMutableDictionary dictionary];
    for (const auto& ext : extensions) {
        NSNumber* key = @(ext.type);
        NSMutableArray<NSData*>* dataArray = result[key];
        if (!dataArray) {
            dataArray = [NSMutableArray array];
            result[key] = dataArray;
        }

        // Even type => intValue, Odd type => arrayValue
        if (ext.type % 2 == 0) {
            // Integer value - encode as 8 bytes big-endian
            uint64_t val = ext.intValue;
            NSData* data = [NSData dataWithBytes:&val length:sizeof(val)];
            [dataArray addObject:data];
        } else if (ext.arrayValue) {
            // Array value - copy from IOBuf
            auto len = ext.arrayValue->computeChainDataLength();
            NSMutableData* data = [NSMutableData dataWithCapacity:len];
            for (auto& buf : *ext.arrayValue) {
                [data appendBytes:buf.data() length:buf.size()];
            }
            [dataArray addObject:data];
        }
    }
    return result;
}

// Convert full moxygen::Extensions to mutable and immutable dictionaries
static void convertMoxygenExtensions(
    const moxygen::Extensions& extensions,
    NSDictionary<NSNumber*, NSArray<NSData*>*>* __strong * mutableOut,
    NSDictionary<NSNumber*, NSArray<NSData*>*>* __strong * immutableOut) {
    *mutableOut = convertExtensions(extensions.getMutableExtensions());
    *immutableOut = convertExtensions(extensions.getImmutableExtensions());
}

// Convert NSDictionary to moxygen Extension vector (reverse direction for publishing)
static std::vector<moxygen::Extension> convertToMoxygenExtensions(
    NSDictionary<NSNumber*, NSArray<NSData*>*>* dict) {
    std::vector<moxygen::Extension> result;
    if (!dict) {
        return result;
    }

    for (NSNumber* key in dict) {
        uint64_t type = [key unsignedLongLongValue];
        NSArray<NSData*>* dataArray = dict[key];
        for (NSData* data in dataArray) {
            moxygen::Extension ext;
            ext.type = type;

            // Even type => intValue, Odd type => arrayValue
            if (type % 2 == 0) {
                // Integer value - read as 8 bytes big-endian (if we have enough bytes)
                if (data.length >= sizeof(uint64_t)) {
                    uint64_t val;
                    memcpy(&val, data.bytes, sizeof(val));
                    ext.intValue = val;
                } else {
                    ext.intValue = 0;
                }
            } else {
                // Array value - copy to IOBuf
                ext.arrayValue = folly::IOBuf::copyBuffer(data.bytes, data.length);
            }
            result.push_back(std::move(ext));
        }
    }
    return result;
}

// Publisher handler that receives incoming subscriptions
class ObjCPublishHandler : public moxygen::Publisher {
public:
    explicit ObjCPublishHandler(__weak MoxygenClientObjC* client) : client_(client) {}

    folly::coro::Task<SubscribeResult> subscribe(
        moxygen::SubscribeRequest sub,
        std::shared_ptr<moxygen::TrackConsumer> callback) override {

        NSLog(@"ObjCPublishHandler: Received SUBSCRIBE for track %s",
              sub.fullTrackName.trackName.c_str());

        // Store the TrackConsumer for this track
        // Use describe() which returns "ns1/ns2/.../nsN/trackName"
        std::string trackKey = sub.fullTrackName.describe();

        NSLog(@"ObjCPublishHandler: Storing consumer with key: %s", trackKey.c_str());
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pendingConsumers_[trackKey] = callback;
            NSLog(@"ObjCPublishHandler: Consumer stored, pendingConsumers size: %zu", pendingConsumers_.size());
        }

        // Create a simple subscription handle
        class SimpleSubscriptionHandle : public moxygen::SubscriptionHandle {
        public:
            explicit SimpleSubscriptionHandle(moxygen::SubscribeOk ok)
                : moxygen::SubscriptionHandle(std::move(ok)) {}

            void unsubscribe() override {
                NSLog(@"ObjCPublishHandler: unsubscribe called");
            }

            folly::coro::Task<SubscribeUpdateResult> subscribeUpdate(
                moxygen::SubscribeUpdate /*subUpdate*/) override {
                co_return folly::makeUnexpected(moxygen::SubscribeUpdateError{
                    moxygen::RequestID(0),
                    moxygen::SubscribeUpdateErrorCode::NOT_SUPPORTED,
                    "not implemented"});
            }
        };

        // Build SubscribeOk response
        moxygen::SubscribeOk subOk;
        subOk.requestID = sub.requestID;
        subOk.trackAlias = moxygen::TrackAlias(sub.requestID.value); // Use requestID as trackAlias
        subOk.expires = std::chrono::milliseconds(0); // No expiration
        // GroupOrder must be explicit (1 or 2), not Default (0)
        subOk.groupOrder = (sub.groupOrder == moxygen::GroupOrder::Default)
            ? moxygen::GroupOrder::NewestFirst
            : sub.groupOrder;

        NSLog(@"ObjCPublishHandler: Returning SubscribeOk for track %s", trackKey.c_str());

        // Notify the client about the new subscriber
        MoxygenClientObjC* strongClient = client_;
        if (strongClient) {
            // Build namespace array from FullTrackName
            NSMutableArray<NSString*>* nsArray = [NSMutableArray array];
            for (const auto& ns : sub.fullTrackName.trackNamespace.trackNamespace) {
                [nsArray addObject:[NSString stringWithUTF8String:ns.c_str()]];
            }
            NSString* trackName = [NSString stringWithUTF8String:sub.fullTrackName.trackName.c_str()];

            dispatch_async(dispatch_get_main_queue(), ^{
                id<MoxygenClientCallbacks> callbacks = [strongClient valueForKey:@"_callbacks"];
                if (callbacks && [callbacks respondsToSelector:@selector(onSubscriberConnected:trackName:)]) {
                    [callbacks onSubscriberConnected:nsArray trackName:trackName];
                }
            });
        }

        co_return std::make_shared<SimpleSubscriptionHandle>(std::move(subOk));
    }

    std::shared_ptr<moxygen::TrackConsumer> getConsumerForTrack(const std::string& trackKey) {
        NSLog(@"ObjCPublishHandler: Looking for consumer with key: %s", trackKey.c_str());
        std::lock_guard<std::mutex> lock(mutex_);
        NSLog(@"ObjCPublishHandler: pendingConsumers size: %zu", pendingConsumers_.size());
        for (const auto& pair : pendingConsumers_) {
            NSLog(@"ObjCPublishHandler: Available key: %s", pair.first.c_str());
        }
        auto it = pendingConsumers_.find(trackKey);
        if (it != pendingConsumers_.end()) {
            NSLog(@"ObjCPublishHandler: Found consumer!");
            auto consumer = it->second;
            pendingConsumers_.erase(it);
            return consumer;
        }
        NSLog(@"ObjCPublishHandler: Consumer NOT found");
        return nullptr;
    }

    bool hasConsumerForTrack(const std::string& trackKey) {
        std::lock_guard<std::mutex> lock(mutex_);
        return pendingConsumers_.find(trackKey) != pendingConsumers_.end();
    }

private:
    __weak MoxygenClientObjC* client_;
    std::mutex mutex_;
    std::map<std::string, std::shared_ptr<moxygen::TrackConsumer>> pendingConsumers_;
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
            uint64_t receiveTicks = mach_absolute_time();

            // Coalesce IOBuf in place if chained, then zero-copy wrap for callback
            payload->coalesce();
            NSData* data = [NSData dataWithBytesNoCopy:(void*)payload->data()
                                               length:payload->length()
                                         freeWhenDone:NO];

            // Convert extensions
            NSDictionary* mutableExts = nil;
            NSDictionary* immutableExts = nil;
            convertMoxygenExtensions(extensions, &mutableExts, &immutableExts);

            // Call synchronously - Swift will copy what it needs
            [strongCallback onObjectReceived:groupId_
                                  subgroupId:subgroupId_
                                    objectId:objectID
                                        data:data
                                  extensions:mutableExts
                        immutableExtensions:immutableExts
                                receiveTicks:receiveTicks];
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
        // Track the expected object length for proper objectPayload handling
        currentObjectId_ = objectID;
        auto payloadLen = initialPayload ? initialPayload->computeChainDataLength() : 0;
        if (length > payloadLen) {
            currentLengthRemaining_ = length - payloadLen;
        } else {
            currentLengthRemaining_.reset();
        }

        // Store extensions for delivery when object is complete
        convertMoxygenExtensions(extensions, &currentMutableExtensions_, &currentImmutableExtensions_);

        // Forward initial payload if present
        if (initialPayload) {
            appendPayload(std::move(initialPayload));
        }

        // If we received the entire object, deliver it now
        if (!currentLengthRemaining_.has_value()) {
            deliverAccumulatedPayload(objectID);
        }
        return folly::unit;
    }

    folly::Expected<moxygen::ObjectPublishStatus, moxygen::MoQPublishError> objectPayload(
        moxygen::Payload payload, bool finSubgroup = false) override {
        if (!currentLengthRemaining_.has_value()) {
            // No active streaming object
            return folly::makeUnexpected(moxygen::MoQPublishError(
                moxygen::MoQPublishError::API_ERROR, "No active streaming object"));
        }

        auto payloadLen = payload ? payload->computeChainDataLength() : 0;
        if (payloadLen > *currentLengthRemaining_) {
            return folly::makeUnexpected(moxygen::MoQPublishError(
                moxygen::MoQPublishError::API_ERROR, "Payload exceeds expected length"));
        }

        *currentLengthRemaining_ -= payloadLen;
        appendPayload(std::move(payload));

        if (*currentLengthRemaining_ == 0) {
            currentLengthRemaining_.reset();
            deliverAccumulatedPayload(currentObjectId_);
            return moxygen::ObjectPublishStatus::DONE;
        }
        return moxygen::ObjectPublishStatus::IN_PROGRESS;
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
    void appendPayload(moxygen::Payload payload) {
        if (payload) {
            if (!accumulatedPayload_) {
                accumulatedPayload_ = std::move(payload);
            } else {
                accumulatedPayload_->appendToChain(std::move(payload));
            }
        }
    }

    void deliverAccumulatedPayload(uint64_t objectID) {
        id<MoxygenTrackCallback> strongCallback = callback_;
        if (strongCallback && accumulatedPayload_) {
            uint64_t receiveTicks = mach_absolute_time();

            // Coalesce IOBuf in place if chained, then zero-copy wrap for callback
            accumulatedPayload_->coalesce();
            NSData* data = [NSData dataWithBytesNoCopy:(void*)accumulatedPayload_->data()
                                               length:accumulatedPayload_->length()
                                         freeWhenDone:NO];

            NSDictionary* mutableExts = currentMutableExtensions_;
            NSDictionary* immutableExts = currentImmutableExtensions_;

            // Call synchronously - Swift will copy what it needs
            [strongCallback onObjectReceived:groupId_
                                  subgroupId:subgroupId_
                                    objectId:objectID
                                        data:data
                                  extensions:mutableExts
                        immutableExtensions:immutableExts
                                receiveTicks:receiveTicks];
        }
        // Clean up after callback returns
        accumulatedPayload_.reset();
        currentMutableExtensions_ = nil;
        currentImmutableExtensions_ = nil;
    }

    uint64_t groupId_;
    uint64_t subgroupId_;
    __weak id<MoxygenTrackCallback> callback_;
    folly::Optional<uint64_t> currentLengthRemaining_;
    uint64_t currentObjectId_{0};
    std::unique_ptr<folly::IOBuf> accumulatedPayload_;
    NSDictionary<NSNumber*, NSArray<NSData*>*>* currentMutableExtensions_{nil};
    NSDictionary<NSNumber*, NSArray<NSData*>*>* currentImmutableExtensions_{nil};
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
            uint64_t receiveTicks = mach_absolute_time();

            // Coalesce IOBuf in place if chained, then zero-copy wrap for callback
            payload->coalesce();
            NSData* data = [NSData dataWithBytesNoCopy:(void*)payload->data()
                                               length:payload->length()
                                         freeWhenDone:NO];

            // Convert extensions from header
            NSDictionary* mutableExts = nil;
            NSDictionary* immutableExts = nil;
            convertMoxygenExtensions(header.extensions, &mutableExts, &immutableExts);

            // Call synchronously - Swift will copy what it needs
            [strongCallback onObjectReceived:header.group
                                  subgroupId:header.subgroup
                                    objectId:header.id
                                        data:data
                                  extensions:mutableExts
                        immutableExtensions:immutableExts
                                receiveTicks:receiveTicks];
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
    uint64_t _lastObjectId;
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
        _lastObjectId = 0;
    }
    return self;
}

- (BOOL)publishObject:(MoxygenObjectHeader *)header data:(NSData *)data {
    return [self publishObject:header data:data extensions:nil immutableExtensions:nil];
}

- (BOOL)publishObject:(MoxygenObjectHeader *)header
                 data:(NSData *)data
           extensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>*)extensions
  immutableExtensions:(NSDictionary<NSNumber*, NSArray<NSData*>*>*)immutableExtensions {
    if (!_trackConsumer) {
        return NO;
    }

    bool success = false;

    _eventBase->runInEventBaseThreadAndWait([self, header, data, extensions, immutableExtensions, &success]() {
        // Create payload from NSData
        auto payload = folly::IOBuf::copyBuffer(data.bytes, data.length);

        // Build ObjectHeader for objectStream
        moxygen::ObjectHeader objHeader;
        objHeader.group = header.groupId;
        objHeader.subgroup = header.subgroupId;
        objHeader.id = header.objectId;
        objHeader.priority = header.priority;
        objHeader.status = moxygen::ObjectStatus::NORMAL;
        objHeader.length = payload->computeChainDataLength();

        // Convert extensions from NSDictionary to moxygen::Extensions
        auto mutableExts = convertToMoxygenExtensions(extensions);
        auto immutableExts = convertToMoxygenExtensions(immutableExtensions);
        objHeader.extensions = moxygen::Extensions(std::move(mutableExts), std::move(immutableExts));

        // Use objectStream for complete single objects - avoids subgroup streaming complexity
        auto result = _trackConsumer->objectStream(objHeader, std::move(payload));
        success = !result.hasError();
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
    std::shared_ptr<ObjCPublishHandler> _publishHandler;
    std::map<std::string, std::shared_ptr<moxygen::Subscriber::AnnounceHandle>> _announceHandles;
    std::mutex _announceHandlesMutex;
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
            // Use MoQRelaySession factory to get full announce/publish support
            _client = std::make_unique<moxygen::MoQClient>(
                _executor,
                std::move(parsedUrl),
                moxygen::MoQRelaySession::createRelaySessionFactory(),
                verifier);
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
                        // Verify session is valid before reporting connected
                        bool sessionValid = selfPtr->_client && selfPtr->_client->moqSession_;
                        NSLog(@"MoxygenClient: setupMoQSession completed, session valid: %d", sessionValid);

                        // Set up publish handler to receive incoming subscriptions
                        if (sessionValid) {
                            selfPtr->_publishHandler = std::make_shared<ObjCPublishHandler>(weakSelf);
                            selfPtr->_client->moqSession_->setPublishHandler(selfPtr->_publishHandler);
                            NSLog(@"MoxygenClient: Publish handler set on session");
                        }

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

    NSLog(@"MoxygenClient: subscribeWithRequest groupOrder=%ld (expected 2 for NewestFirst)",
          (long)request.groupOrder);

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
    if (_status != MoxygenConnectionStatusConnected) {
        NSLog(@"MoxygenClient: announceNamespace failed - not connected");
        return NO;
    }
    if (!_client || !_client->moqSession_) {
        NSLog(@"MoxygenClient: announceNamespace failed - no session");
        return NO;
    }

    // Build TrackNamespace
    std::vector<std::string> ns;
    for (NSString* item in trackNamespace) {
        ns.push_back([item UTF8String]);
    }
    moxygen::TrackNamespace trackNs(std::move(ns));

    NSLog(@"MoxygenClient: Announcing namespace with %lu components", (unsigned long)trackNamespace.count);

    // Use shared_ptr for state that needs to be captured by C++ lambdas
    struct AnnounceState {
        std::atomic<bool> success{false};
        std::string errorMsg;
        std::shared_ptr<moxygen::Subscriber::AnnounceHandle> handle;
        std::mutex mutex;
    };
    auto state = std::make_shared<AnnounceState>();
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    // Build namespace key for storage
    std::string nsKey;
    for (NSString* item in trackNamespace) {
        if (!nsKey.empty()) nsKey += "/";
        nsKey += [item UTF8String];
    }

    _eventBase->runInEventBaseThread([self, trackNs = std::move(trackNs), state, semaphore, nsKey]() mutable {
        if (!self->_client || !self->_client->moqSession_) {
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->errorMsg = "session became nil";
            }
            dispatch_semaphore_signal(semaphore);
            return;
        }

        // Create Announce request
        moxygen::Announce announce;
        announce.trackNamespace = std::move(trackNs);

        // Call announce on the session asynchronously
        self->_client->moqSession_->announce(std::move(announce), nullptr)
            .scheduleOn(self->_executor.get())
            .start([self, state, semaphore, nsKey](folly::Try<moxygen::Subscriber::AnnounceResult>&& result) {
                if (result.hasException()) {
                    std::string errMsg;
                    try {
                        result.throwUnlessValue();
                    } catch (const std::exception& e) {
                        errMsg = e.what();
                    }
                    {
                        std::lock_guard<std::mutex> lock(state->mutex);
                        state->errorMsg = errMsg;
                    }
                    NSLog(@"MoxygenClient: announce exception: %s", errMsg.c_str());
                } else {
                    auto& annResult = result.value();
                    if (annResult.hasError()) {
                        std::string errMsg = annResult.error().reasonPhrase;
                        {
                            std::lock_guard<std::mutex> lock(state->mutex);
                            state->errorMsg = errMsg;
                        }
                        NSLog(@"MoxygenClient: announce error: %s", errMsg.c_str());
                    } else {
                        // Store the announce handle to keep it alive
                        auto handle = annResult.value();
                        {
                            std::lock_guard<std::mutex> lock(self->_announceHandlesMutex);
                            self->_announceHandles[nsKey] = handle;
                        }
                        NSLog(@"MoxygenClient: announce succeeded, handle stored for %s", nsKey.c_str());
                        state->success = true;
                    }
                }
                dispatch_semaphore_signal(semaphore);
            });
    });

    // Wait for announce to complete (with timeout)
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        NSLog(@"MoxygenClient: announceNamespace timed out");
        return NO;
    }

    if (!state->success) {
        std::lock_guard<std::mutex> lock(state->mutex);
        NSLog(@"MoxygenClient: announceNamespace failed - %s", state->errorMsg.c_str());
    }
    return state->success ? YES : NO;
}

- (MoxygenPublisher *)createPublisherWithNamespace:(NSArray<NSString *> *)trackNamespace
                                         trackName:(NSString *)trackName
                                        groupOrder:(MoxygenGroupOrder)groupOrder {
    NSLog(@"MoxygenClient: createPublisher called - namespace: %@, track: %@, status: %ld",
          trackNamespace, trackName, (long)_status);

    if (_status != MoxygenConnectionStatusConnected) {
        NSLog(@"MoxygenClient: createPublisher failed - not connected (status=%ld)", (long)_status);
        return nil;
    }
    if (!_client) {
        NSLog(@"MoxygenClient: createPublisher failed - client is nil");
        return nil;
    }
    if (!_client->moqSession_) {
        NSLog(@"MoxygenClient: createPublisher failed - moqSession is nil");
        return nil;
    }

    NSLog(@"MoxygenClient: Session is valid, building publish request");

    // Build FullTrackName
    std::vector<std::string> ns;
    for (NSString* item in trackNamespace) {
        ns.push_back([item UTF8String]);
    }
    moxygen::FullTrackName fullTrackName;
    fullTrackName.trackNamespace = moxygen::TrackNamespace(std::move(ns));
    fullTrackName.trackName = [trackName UTF8String];

    // Build track key for looking up pending consumers
    // Format must match FullTrackName::describe(): "ns1/ns2/.../nsN/trackName"
    std::string trackKey = fullTrackName.describe();

    NSLog(@"MoxygenClient: Creating publisher for track key: %s", trackKey.c_str());

    std::shared_ptr<moxygen::TrackConsumer> trackConsumer;
    bool success = false;
    std::string errorMsg;

    // First, check if we already have a TrackConsumer from an incoming subscription
    if (_publishHandler) {
        trackConsumer = _publishHandler->getConsumerForTrack(trackKey);
        if (trackConsumer) {
            NSLog(@"MoxygenClient: Found pending TrackConsumer from subscription");
            success = true;
        }
    }

    // If no pending consumer, try the proactive publish approach
    if (!success) {
        NSLog(@"MoxygenClient: No pending subscription, trying proactive publish()");

        // Build PublishRequest
        moxygen::PublishRequest pubRequest;
        pubRequest.fullTrackName = fullTrackName;
        pubRequest.groupOrder = static_cast<moxygen::GroupOrder>(groupOrder);

        _eventBase->runInEventBaseThreadAndWait([self, pubRequest = std::move(pubRequest),
                                                  &trackConsumer, &success, &errorMsg]() mutable {
            if (!self->_client || !self->_client->moqSession_) {
                errorMsg = "client or session became nil on event thread";
                return;
            }

            LOG(INFO) << "MoxygenClient: Calling moqSession_->publish()";
            auto result = self->_client->moqSession_->publish(std::move(pubRequest), nullptr);
            if (result.hasError()) {
                errorMsg = result.error().reasonPhrase;
                LOG(ERROR) << "MoxygenClient: publish() error: " << errorMsg;
                // This is expected in reactive mode - we need a subscriber first
                return;
            }
            if (!result.value().consumer) {
                errorMsg = "publish succeeded but consumer is nil";
                LOG(ERROR) << "MoxygenClient: " << errorMsg;
                return;
            }
            LOG(INFO) << "MoxygenClient: publish() succeeded, got consumer";
            trackConsumer = result.value().consumer;
            success = true;
        });

        NSLog(@"MoxygenClient: publish() completed - success: %d, error: %s",
              success, errorMsg.c_str());
    }

    if (!success || !trackConsumer) {
        NSLog(@"MoxygenClient: createPublisher failed - %s", errorMsg.c_str());
        return nil;
    }

    NSLog(@"MoxygenClient: Publisher created successfully");
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

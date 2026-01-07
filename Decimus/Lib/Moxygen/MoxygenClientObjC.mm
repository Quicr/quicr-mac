// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#import "MoxygenClientObjC.h"

#include <moxygen/MoQClient.h>
#include <moxygen/MoQFramer.h>
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

} // namespace

@implementation MoxygenClientConfig

- (instancetype)init {
    self = [super init];
    if (self) {
        _connectURL = @"https://127.0.0.1:4433/relay";
        _connectTimeout = 5.0;
    }
    return self;
}

@end

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

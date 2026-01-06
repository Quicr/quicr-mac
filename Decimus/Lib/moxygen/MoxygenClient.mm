// SPDX-FileCopyrightText: Copyright (c) 2024
// SPDX-License-Identifier: BSD-2-Clause

#import "MoxygenClient.h"

// Define gflags verbose logging level (required by folly/proxygen)
// This is normally defined by glog initialization, but we define it here
// to avoid pulling in the full glog dynamic library.
#include <gflags/gflags.h>
DEFINE_int32(v, 0, "Verbose logging level for VLOG");

#include <moxygen/MoQClient.h>
#include <moxygen/MoQFramer.h>
#include <moxygen/events/MoQFollyExecutorImpl.h>
#include <proxygen/lib/utils/URL.h>
#include <folly/io/async/ScopedEventBaseThread.h>

#include <thread>
#include <atomic>

#pragma mark - MoxygenClientImpl

/// Internal C++ implementation class
class MoxygenClientImpl : public moxygen::Subscriber,
                          public moxygen::Publisher,
                          public std::enable_shared_from_this<MoxygenClientImpl> {
public:
    MoxygenClientImpl(const std::string& url, bool useLegacy)
        : url_(url), useLegacyAlpn_(useLegacy) {}

    ~MoxygenClientImpl() {
        stop();
    }

    using StatusCallback = std::function<void(MoxygenConnectionStatus, const std::string&)>;

    void setStatusCallback(StatusCallback cb) {
        statusCallback_ = std::move(cb);
    }

    void start(std::chrono::milliseconds connectTimeout,
               std::chrono::seconds transactionTimeout) {
        if (running_.exchange(true)) {
            return; // Already running
        }

        connectTimeout_ = connectTimeout;
        transactionTimeout_ = transactionTimeout;

        // Create a scoped event base thread (folly's async runtime)
        evbThread_ = std::make_unique<folly::ScopedEventBaseThread>("MoxygenEvb");
        auto* evb = evbThread_->getEventBase();

        // Create the moxygen executor
        executor_ = std::make_shared<moxygen::MoQFollyExecutorImpl>(evb);

        // Parse URL and create client
        proxygen::URL parsedUrl(url_);
        if (!parsedUrl.isValid() || !parsedUrl.hasHost()) {
            reportStatus(MoxygenConnectionStatusFailed, "Invalid URL: " + url_);
            running_ = false;
            return;
        }

        moqClient_ = std::make_unique<moxygen::MoQClient>(executor_, std::move(parsedUrl));

        // Report connecting status
        reportStatus(MoxygenConnectionStatusConnecting, "");

        // Start connection coroutine on the event base
        auto self = shared_from_this();
        evb->runInEventBaseThread([this, self]() {
            connectAsync().scheduleOn(executor_.get()).start();
        });
    }

    void stop() {
        if (!running_.exchange(false)) {
            return; // Already stopped
        }

        // Close the session if connected
        if (moqClient_ && moqClient_->moqSession_) {
            moqClient_->moqSession_->close(moxygen::SessionCloseErrorCode::NO_ERROR);
        }

        moqClient_.reset();
        executor_.reset();

        // Stop the event base thread
        evbThread_.reset();

        connected_ = false;
    }

    bool isConnected() const {
        return connected_.load();
    }

    std::string getConnectionInfo() const {
        if (!moqClient_ || !moqClient_->moqSession_) {
            return "Not connected";
        }

        auto version = moqClient_->moqSession_->getNegotiatedVersion();
        if (version) {
            return "Connected, MoQT draft-" + std::to_string(*version & 0xFF);
        }
        return "Connected, version unknown";
    }

    // Subscriber interface - for receiving announcements
    void goaway(moxygen::Goaway goaway) override {
        if (goawayCallback_) {
            goawayCallback_(goaway.newSessionUri);
        }
    }

    using GoawayCallback = std::function<void(const std::string&)>;
    void setGoawayCallback(GoawayCallback cb) {
        goawayCallback_ = std::move(cb);
    }

    moxygen::MoQSession* getSession() const {
        if (moqClient_ && moqClient_->moqSession_) {
            return moqClient_->moqSession_.get();
        }
        return nullptr;
    }

private:
    folly::coro::Task<void> connectAsync() {
        try {
            // Get ALPN protocols based on settings
            std::vector<std::string> alpns = moxygen::getDefaultMoqtProtocols(!useLegacyAlpn_);

            // Setup the MoQ session
            co_await moqClient_->setupMoQSession(
                connectTimeout_,
                transactionTimeout_,
                /*publishHandler=*/nullptr,  // We'll set handlers later when needed
                /*subscribeHandler=*/shared_from_this(),
                quic::TransportSettings(),
                alpns
            );

            connected_ = true;
            reportStatus(MoxygenConnectionStatusConnected, "");

        } catch (const std::exception& ex) {
            connected_ = false;
            reportStatus(MoxygenConnectionStatusFailed, ex.what());
        }
    }

    void reportStatus(MoxygenConnectionStatus status, const std::string& error) {
        if (statusCallback_) {
            statusCallback_(status, error);
        }
    }

    std::string url_;
    bool useLegacyAlpn_{false};
    std::chrono::milliseconds connectTimeout_{1000};
    std::chrono::seconds transactionTimeout_{120};

    std::unique_ptr<folly::ScopedEventBaseThread> evbThread_;
    std::shared_ptr<moxygen::MoQFollyExecutorImpl> executor_;
    std::unique_ptr<moxygen::MoQClient> moqClient_;

    std::atomic<bool> running_{false};
    std::atomic<bool> connected_{false};

    StatusCallback statusCallback_;
    GoawayCallback goawayCallback_;
};

#pragma mark - MoxygenClientConfig

@implementation MoxygenClientConfig

- (instancetype)initWithUrl:(NSString *)url {
    self = [super init];
    if (self) {
        _connectUrl = [url copy];
        _connectTimeoutMs = 1000;
        _transactionTimeoutSec = 120;
        _useLegacyAlpn = NO;
    }
    return self;
}

@end

#pragma mark - MoxygenClient

@interface MoxygenClient ()
@property (nonatomic, assign) MoxygenConnectionStatus connectionStatus;
@end

@implementation MoxygenClient {
    std::shared_ptr<MoxygenClientImpl> _impl;
    MoxygenClientConfig *_config;
}

- (instancetype)initWithConfig:(MoxygenClientConfig *)config {
    self = [super init];
    if (self) {
        _config = config;
        _connectionStatus = MoxygenConnectionStatusDisconnected;

        std::string urlStr = std::string([config.connectUrl UTF8String]);
        _impl = std::make_shared<MoxygenClientImpl>(urlStr, config.useLegacyAlpn);

        __weak MoxygenClient *weakSelf = self;
        _impl->setStatusCallback([weakSelf](MoxygenConnectionStatus status, const std::string& error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MoxygenClient *strongSelf = weakSelf;
                if (!strongSelf) return;

                strongSelf.connectionStatus = status;

                if (status == MoxygenConnectionStatusFailed && !error.empty()) {
                    NSString *errorStr = [NSString stringWithUTF8String:error.c_str()];
                    [strongSelf.delegate moxygenClient:strongSelf connectionFailedWithError:errorStr];
                } else {
                    [strongSelf.delegate moxygenClient:strongSelf connectionStatusChanged:status];
                }
            });
        });

        _impl->setGoawayCallback([weakSelf](const std::string& newUri) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MoxygenClient *strongSelf = weakSelf;
                if (!strongSelf) return;

                NSString *uriStr = [NSString stringWithUTF8String:newUri.c_str()];
                if ([strongSelf.delegate respondsToSelector:@selector(moxygenClientReceivedGoaway:newUri:)]) {
                    [strongSelf.delegate moxygenClientReceivedGoaway:strongSelf newUri:uriStr];
                }
            });
        });
    }
    return self;
}

- (void)connect {
    if (_connectionStatus == MoxygenConnectionStatusConnecting ||
        _connectionStatus == MoxygenConnectionStatusConnected) {
        return;
    }

    auto connectTimeout = std::chrono::milliseconds(static_cast<int64_t>(_config.connectTimeoutMs));
    auto transactionTimeout = std::chrono::seconds(static_cast<int64_t>(_config.transactionTimeoutSec));

    _impl->start(connectTimeout, transactionTimeout);
}

- (void)disconnect {
    _impl->stop();
    self.connectionStatus = MoxygenConnectionStatusDisconnected;
}

- (NSString *)connectionInfo {
    if (!_impl) {
        return nil;
    }
    std::string info = _impl->getConnectionInfo();
    return [NSString stringWithUTF8String:info.c_str()];
}

- (NSString *)supportedVersions {
    // Build supported versions string from the kSupportedVersions array
    NSMutableArray *versions = [NSMutableArray array];
    for (uint64_t v : moxygen::kSupportedVersions) {
        [versions addObject:[NSString stringWithFormat:@"draft-%llu", (unsigned long long)(v & 0xFF)]];
    }
    return [versions componentsJoinedByString:@", "];
}

- (void)dealloc {
    _impl->stop();
}

@end

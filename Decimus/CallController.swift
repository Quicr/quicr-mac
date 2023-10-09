import CoreMedia
import AVFoundation
import os

/// Implementation of the QController interface to control QMedia.
class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {

    /// Possible errors generated on CallController.Connect.
    enum CallError: Error {
        /// Underlying QMedia failure.
        /// - Parameter _ QMedia return code.
        case failedToConnect(Int32)
    }
    
    private let config: SubscriptionConfig
    private static let logger = DecimusLogger(CallController.self)

    /// Create a new CallController / QMedia instance and Publisher/Subscriber delegates
    /// to handle creation of publications and subscriptions on demand.
    /// - Parameter metricsSubmitter An object to submit collected metrics through.
    /// - Parameter captureManager Source of video frames.
    /// - Parameter config Additional user provided configuration for publications/subscriptions.
    /// - Parameter engine Source of audio data and playout capabilities.
    /// - Parameter granularMetrics True to record highly granular metrics, at some performance cost.
    init(metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         config: SubscriptionConfig,
         engine: DecimusAudioEngine,
         granularMetrics: Bool) throws {
        self.config = config
        super.init { level, msg, alert in
            CallController.logger.log(level: DecimusLogger.LogLevel(rawValue: level)!, msg!, alert: alert)
        }
        self.subscriberDelegate = SubscriberDelegate(submitter: metricsSubmitter,
                                                     config: config,
                                                     engine: engine,
                                                     granularMetrics: granularMetrics)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager,
                                                   opusWindowSize: config.opusWindowSize,
                                                   reliability: config.mediaReliability,
                                                   engine: engine,
                                                   granularMetrics: granularMetrics)
    }

    /// Retrieve the manifest for the given conference, and connect to it.
    /// - Parameter config The details of the call / conference to join.
    func connect(config: CallConfig) async throws {
        let transportConfig: TransportConfig = .init(tls_cert_filename: nil,
                                                     tls_key_filename: nil,
                                                     time_queue_init_queue_size: 1000,
                                                     time_queue_max_duration: 1000,
                                                     time_queue_bucket_interval: 1,
                                                     time_queue_size_rx: 1000,
                                                     debug: false,
                                                     quic_cwin_minimum: self.config.quicCwinMinimumKiB * 1024)
        let error = super.connect(config.address,
                                  port: config.port,
                                  protocol: config.connectionProtocol.rawValue,
                                  config: transportConfig)
        guard error == .zero else {
            throw CallError.failedToConnect(error)
        }

        // TODO: Should we not attempt the fetch of the manifest prior to connecting?
        let manifest = try await ManifestController.shared.getManifest(confId: config.conferenceID, email: config.email)

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted

        let manifestJSON = try jsonEncoder.encode(manifest)
        super.updateManifest(String(data: manifestJSON, encoding: .utf8)!)
    }

    /// Disconnect from the conference and shutdown QMedia.
    func disconnect() throws {
        super.close()
    }
}

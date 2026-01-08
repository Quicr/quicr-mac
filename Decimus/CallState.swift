// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFoundation
import CryptoKit
import SFrame
import SwiftUI
import Synchronization
import Network

class SFrameContext {
    let mutex: Mutex<MLS>

    init(_ sframe: MLS) {
        self.mutex = .init(sframe)
    }
}

class SendSFrameContext {
    let context: SFrameContext
    let senderId: MLS.SenderID
    let currentEpoch: MLS.EpochID

    init(sframe: MLS, senderId: MLS.SenderID, currentEpoch: MLS.EpochID) {
        self.context = .init(sframe)
        self.senderId = senderId
        self.currentEpoch = currentEpoch
    }
}

struct SFrameConfig: Codable {
    let enable: Bool
    let secret: String
}

enum MoQRole: Int, CaseIterable, Identifiable, CustomStringConvertible {
    case publisher
    case subscriber
    case both

    var id: Int { self.rawValue }
    var description: String {
        switch self {
        case .publisher: "Publisher"
        case .subscriber: "Subscriber"
        case .both: "Both"
        }
    }
}

enum MoQStack: Int, CaseIterable, Identifiable, CustomStringConvertible {
    case libquicr
    case moxygen

    var id: Int { self.rawValue }
    var description: String {
        switch self {
        case .libquicr: "libquicr"
        case .moxygen: "moxygen"
        }
    }
}

@MainActor
class CallState: ObservableObject, Equatable {
    nonisolated static func == (lhs: CallState, rhs: CallState) -> Bool {
        false
    }

    private static let logger = DecimusLogger(CallState.self)

    let engine: DecimusAudioEngine?
    private(set) var controller: MoqCallController?
    private(set) var activeSpeaker: ActiveSpeakerApply<VideoSubscription>?
    private(set) var manualActiveSpeaker: ManualActiveSpeaker?
    private(set) var captureManager: CaptureManager?
    private(set) var activeSpeakerStats: ActiveSpeakerStats?
    private(set) var videoParticipants = VideoParticipants()
    private(set) var currentManifest: Manifest?
    private(set) var textSubscriptions: TextSubscriptions?
    private(set) var textPublication: TextPublication?
    private let config: CallConfig
    private var appMetricTimer: Task<(), Error>?
    private var measurement: MeasurementRegistration<_Measurement>?
    private var submitter: MetricsSubmitter?
    private var audioCapture = false
    private var videoCapture = false
    let onLeave: () -> Void
    var relayId: String?
    private(set) var publicationFactory: PublicationFactory?
    private(set) var subscriptionFactory: SubscriptionFactoryImpl?
    private let joinDate = Date.now
    let audioStartingGroup: UInt64?
    private var sendContext: SendSFrameContext?
    private var receiveContext: SFrameContext?
    private var moxygenClient: MoxygenClientObjC?
    private var moxygenCallbacks: MoxygenCallbackHandler?
    private var moxygenVideoPublication: H264Publication?
    private var moxygenVideoSubscriptions: [MoxygenVideoSubscription] = []

    @AppStorage(SubscriptionSettingsView.showLabelsKey)
    var showLabels: Bool = true

    @AppStorage("influxConfig")
    private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

    @AppStorage("subscriptionConfig")
    private(set) var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

    @AppStorage(PlaytimeSettingsView.defaultsKey)
    private(set) var playtimeConfig: AppStorageWrapper<PlaytimeSettings> = .init(value: .init())

    @AppStorage(SettingsView.verboseKey)
    private(set) var verbose = false

    @AppStorage(SettingsView.moqRoleKey)
    private(set) var role = MoQRole.both
    @AppStorage(SettingsView.moqStackKey)
    private(set) var moqStack = MoQStack.libquicr
    @AppStorage(SettingsView.mediaInteropKey)
    private(set) var mediaInterop = false
    @AppStorage(SettingsView.useOverrideNamespaceKey)
    private(set) var useOverrideNamespace = false
    @AppStorage(SettingsView.overrideNamespaceKey)
    private(set) var overrideNamespaceJSON: String = ""
    nonisolated static let namespaceSourcePlaceholder = "{s}"
    private var resolvedNamespace: [String]?

    // Subscribe namespace.
    @AppStorage(SettingsView.subscribeNamespaceEnabledKey)
    private var subscribeNamespaceEnabled = false
    @AppStorage(SettingsView.subscribeNamespaceKey)
    private var subscribeNamespace: String = ""
    @AppStorage(SettingsView.subscribeNamespaceAcceptKey)
    private var subscribeNamespaceAccept: String = ""
    private var subscriptionNamespaceAcceptParsed: [Data]?

    // Recording.
    @AppStorage(SettingsView.recordingKey)
    private(set) var recording = false
    @AppStorage(DisplayPicker.displayRecordKey)
    private var recordDisplay: Int = 0
    private var appRecorder: AppRecorder?

    #if os(macOS)
    private var wlan: CoreWLANWiFiScanNotifier?
    #endif

    init(config: CallConfig, audioStartingGroup: UInt64?, onLeave: @escaping () -> Void) {
        self.config = config
        self.audioStartingGroup = audioStartingGroup
        self.onLeave = onLeave
        do {
            self.engine = try .init()
        } catch {
            Self.logger.error("Failed to create AudioEngine: \(error.localizedDescription)")
            self.engine = nil
        }

        if influxConfig.value.submit {
            let tags: [String: String] = [
                "relay": config.address,
                "email": config.email,
                "conference": "\(config.conferenceID)"
            ]
            self.doMetrics(tags)
        }

        do {
            self.captureManager = try .init(metricsSubmitter: submitter,
                                            granularMetrics: influxConfig.value.granular)
        } catch {
            Self.logger.error("Failed to create camera manager: \(error.localizedDescription)")
        }
    }

    func join(make: Bool = true) async -> Bool { // swiftlint:disable:this function_body_length cyclomatic_complexity
        // Recording.
        if self.recording {
            do {
                #if canImport(ScreenCaptureKit)
                let filename = "quicr_\(self.config.email)_\(self.config.conferenceID)_\(Date.now.ISO8601Format())"
                self.appRecorder = try await AppRecorderImpl(filename: filename, display: .init(self.recordDisplay))
                #endif
            } catch {
                Self.logger.error("Failed to start recording: \(error.localizedDescription)")
            }
        }

        // Fetch the manifest from the conference server.
        let manifest: Manifest
        do {
            let mController = ManifestController.shared
            manifest = try await mController.getManifest(confId: self.config.conferenceID,
                                                         email: self.config.email)
        } catch {
            Self.logger.error("Failed to fetch manifest: \(error.localizedDescription)")
            return false
        }
        self.currentManifest = manifest

        let sframeSettings = self.subscriptionConfig.value.sframeSettings
        if sframeSettings.enable {
            let epochId: MLS.EpochID = 0
            do {
                guard let suite = registry[.aes_128_gcm_sha256_128] else {
                    throw "Unsupported CipherSuite"
                }
                let cryptoProvider = SwiftCryptoProvider(suite: suite)
                let sendContext = try MLS(provider: cryptoProvider, epochBits: 1)
                let recvContext = try MLS(provider: cryptoProvider, epochBits: 1)

                let secret = SymmetricKey(data: Data(sframeSettings.key.utf8))
                try sendContext.addEpoch(epochId: epochId,
                                         sframeEpochSecret: secret)
                try recvContext.addEpoch(epochId: epochId,
                                         sframeEpochSecret: secret)

                let senderId = self.audioStartingGroup ?? UInt64(manifest.participantId.aggregate)
                self.sendContext = .init(sframe: sendContext,
                                         senderId: senderId,
                                         currentEpoch: epochId)
                self.receiveContext = .init(recvContext)
            } catch {
                Self.logger.error("Failed to create SFrame context: \(error.localizedDescription)")
            }
        }

        self.textSubscriptions = .init(sframeContext: self.receiveContext)

        // Are we overriding publication namespaces?
        let overrideNamespace: [String]?
        if self.mediaInterop {
            let (override, namespaceError) = Self.validateNamespace(self.overrideNamespaceJSON, placeholder: true)
            if let namespaceError {
                Self.logger.error("Bad override namespace: \(namespaceError)")
                return false
            }
            guard let override else {
                assert(false)
                Self.logger.error("Bad namespace override")
                return false
            }
            overrideNamespace = override
        } else {
            overrideNamespace = nil
        }
        self.resolvedNamespace = overrideNamespace

        // Create the factories now that we have the participant ID.
        let subConfig = self.subscriptionConfig.value
        let publicationFactory: PublicationFactory?
        if self.role != .subscriber {
            publicationFactory = PublicationFactoryImpl(opusWindowSize: subConfig.opusWindowSize,
                                                        reliability: subConfig.mediaReliability,
                                                        engine: self.engine,
                                                        metricsSubmitter: self.submitter,
                                                        granularMetrics: self.influxConfig.value.granular,
                                                        captureManager: self.captureManager,
                                                        participantId: manifest.participantId,
                                                        keyFrameInterval: subConfig.keyFrameInterval,
                                                        stagger: subConfig.stagger,
                                                        verbose: self.verbose,
                                                        keyFrameOnUpdate: subConfig.keyFrameOnSubscribeUpdate,
                                                        startingGroup: self.audioStartingGroup,
                                                        sframeContext: self.sendContext,
                                                        mediaInterop: self.mediaInterop,
                                                        overrideNamespace: overrideNamespace,
                                                        useAnnounce: subConfig.useAnnounce)
        } else {
            publicationFactory = nil
        }
        let playtime = self.playtimeConfig.value
        let ourParticipantId = (playtime.playtime && playtime.echo) ? nil : manifest.participantId

        // Branch based on MoQ stack selection
        if self.moqStack == .moxygen {
            let moxygenConfig = MoxygenClientConfig()
            moxygenConfig.connectURL = self.config.address
            moxygenConfig.connectTimeout = 5
            let client = MoxygenClientObjC(config: moxygenConfig)
            let callbacks = MoxygenCallbackHandler()
            client.setCallbacks(callbacks)
            self.moxygenClient = client
            self.moxygenCallbacks = callbacks
            Self.logger.info("Moxygen: Connecting to \(self.config.address)")
            client.connect()

            // Await connection result
            let connected = await callbacks.awaitConnection()
            guard connected else {
                let error = callbacks.getLastError() ?? "Unknown error"
                Self.logger.error("Moxygen connection failed: \(error)")
                return false
            }
            Self.logger.info("Moxygen: Connected successfully")

            // Set up video publication if we have a camera
            if self.role != .subscriber, let captureManager = self.captureManager {
                do {
                    // Find video publication from manifest
                    guard let videoPublication = manifest.publications.first(where: {
                        $0.mediaType == ManifestMediaTypes.video.rawValue
                    }) else {
                        Self.logger.warning("No video publication in manifest for moxygen")
                        return true
                    }

                    // Get first video profile and codec config
                    guard let profile = videoPublication.profileSet.profiles.first else {
                        Self.logger.warning("No video profile in manifest")
                        return true
                    }

                    let codecFactory = CodecFactoryImpl()
                    guard let config = codecFactory.makeCodecConfig(from: profile.qualityProfile,
                                                                     bitrateType: .average) as? VideoCodecConfig else {
                        Self.logger.warning("Failed to create video codec config")
                        return true
                    }

                    // Get camera device
                    let device: AVCaptureDevice
                    #if os(macOS)
                    guard let externalCamera = AVCaptureDevice.default(.external, for: .video, position: .unspecified) else {
                        Self.logger.warning("No camera available for moxygen video publication")
                        return true
                    }
                    device = externalCamera
                    #else
                    if #available(iOS 17.0, tvOS 17.0, *) {
                        guard let preferred = AVCaptureDevice.systemPreferredCamera else {
                            Self.logger.warning("No camera available for moxygen video publication")
                            return true
                        }
                        device = preferred
                    } else {
                        guard let preferred = AVCaptureDevice.default(for: .video) else {
                            Self.logger.warning("No camera available for moxygen video publication")
                            return true
                        }
                        device = preferred
                    }
                    #endif

                    // Announce the namespace so the relay knows we can publish
                    if !client.announceNamespace(profile.namespace) {
                        Self.logger.warning("Moxygen: Failed to announce namespace - relay may not support announce")
                    } else {
                        Self.logger.info("Moxygen: Announced namespace \(profile.namespace)")
                    }

                    // Set up handler to create publisher when a subscriber connects
                    // Moxygen uses a reactive model - publish only works when subscribers are connected
                    let publisherNamespace = profile.namespace
                    callbacks.onSubscriberConnectedHandler = { [weak self, weak client] namespace, trackName in
                        guard let self = self,
                              let client = client,
                              trackName == "video",
                              namespace == publisherNamespace,
                              self.moxygenVideoPublication == nil else { return }

                        Self.logger.info("Moxygen: Subscriber connected, creating publisher")

                        guard let moxygenPublisher = client.createPublisher(withNamespace: namespace,
                                                                             trackName: trackName,
                                                                             groupOrder: .newestFirst) else {
                            Self.logger.error("Moxygen: Failed to create publisher after subscriber connected")
                            return
                        }

                        do {
                            let sink = MoxygenVideoSink(publisher: moxygenPublisher)
                            let keyFrameInterval = self.subscriptionConfig.value.keyFrameInterval
                            let encoder = try VTEncoder(config: config,
                                                        verticalMirror: device.position == .front,
                                                        emitStartCodes: false,
                                                        keyFrameInterval: keyFrameInterval)
                            let publication = try H264Publication(profile: profile,
                                                                  config: config,
                                                                  metricsSubmitter: self.submitter,
                                                                  granularMetrics: self.influxConfig.value.granular,
                                                                  encoder: encoder,
                                                                  device: device,
                                                                  stagger: subConfig.stagger,
                                                                  verbose: self.verbose,
                                                                  sframeContext: self.sendContext,
                                                                  mediaInterop: self.mediaInterop,
                                                                  sink: sink)
                            self.moxygenVideoPublication = publication

                            try captureManager.addInput(publication)
                            try captureManager.startCapturing()
                            self.videoCapture = true
                            Self.logger.info("Moxygen: Video publication started after subscriber connected")
                        } catch {
                            Self.logger.error("Moxygen: Failed to start publication: \(error.localizedDescription)")
                        }
                    }

                    // Try to create publisher immediately (might fail if no subscribers yet)
                    if let moxygenPublisher = client.createPublisher(withNamespace: profile.namespace,
                                                                      trackName: "video",
                                                                      groupOrder: .newestFirst) {
                        // Create sink and publication
                        let sink = MoxygenVideoSink(publisher: moxygenPublisher)
                        let keyFrameInterval = self.subscriptionConfig.value.keyFrameInterval
                        let encoder = try VTEncoder(config: config,
                                                    verticalMirror: device.position == .front,
                                                    emitStartCodes: false,
                                                    keyFrameInterval: keyFrameInterval)
                        let publication = try H264Publication(profile: profile,
                                                              config: config,
                                                              metricsSubmitter: self.submitter,
                                                              granularMetrics: self.influxConfig.value.granular,
                                                              encoder: encoder,
                                                              device: device,
                                                              stagger: subConfig.stagger,
                                                              verbose: self.verbose,
                                                              sframeContext: self.sendContext,
                                                              mediaInterop: self.mediaInterop,
                                                              sink: sink)
                        self.moxygenVideoPublication = publication

                        // Add to capture manager and start
                        try captureManager.addInput(publication)
                        try captureManager.startCapturing()
                        self.videoCapture = true
                        Self.logger.info("Moxygen: Video publication started")
                    } else {
                        Self.logger.info("Moxygen: No subscribers yet - will start publishing when subscriber connects")
                    }
                } catch {
                    Self.logger.error("Failed to set up moxygen video publication: \(error.localizedDescription)")
                }
            }

            // Set up video subscriptions for moxygen
            if self.role != .publisher {
                let factoryConfig = MoxygenVideoSubscriptionConfig(
                    videoParticipants: self.videoParticipants,
                    metricsSubmitter: self.submitter,
                    subscriptionConfig: self.subscriptionConfig.value,
                    granularMetrics: self.influxConfig.value.granular,
                    joinDate: self.joinDate,
                    activeSpeakerStats: self.activeSpeakerStats,
                    verbose: self.verbose,
                    calculateLatency: self.showLabels,
                    mediaInterop: self.mediaInterop
                )
                let subscriptionFactory = MoxygenVideoSubscriptionFactory(config: factoryConfig)

                for subscription in manifest.subscriptions where subscription.mediaType == ManifestMediaTypes.video.rawValue {
                    // Create a shared variance calculator per subscription set
                    let variances = try! VarianceCalculator(expectedOccurrences: 10) // swiftlint:disable force_try

                    for profile in subscription.profileSet.profiles {
                        let request = MoxygenSubscribeRequest()
                        request.trackNamespace = profile.namespace
                        request.trackName = "video"
                        request.priority = 0
                        request.groupOrder = .newestFirst

                        let trackKey = profile.namespace.joined(separator: "/") + "/video"

                        do {
                            let videoSubscription = try subscriptionFactory.create(
                                profile: profile,
                                participantId: subscription.participantId,
                                variances: variances
                            )
                            self.moxygenVideoSubscriptions.append(videoSubscription)

                            Self.logger.info("Moxygen: Subscribing to \(trackKey)")
                            if client.subscribe(with: request, callback: videoSubscription) {
                                Self.logger.info("Moxygen: Subscribe request sent for \(trackKey)")
                            } else {
                                Self.logger.error("Moxygen: Failed to subscribe to \(trackKey)")
                            }
                        } catch {
                            Self.logger.error("Moxygen: Failed to create subscription for \(trackKey): \(error)")
                        }
                    }
                }
            }

            return true
        }

        // libquicr path
        let controller = self.makeCallController(overrideNamespace: overrideNamespace)
        self.controller = controller
        let startingGroupId: UInt64? = playtime.echo ? nil : self.audioStartingGroup
        let subscriptionFactory: SubscriptionFactoryImpl?
        if self.role != .publisher {
            subscriptionFactory = SubscriptionFactoryImpl(videoParticipants: self.videoParticipants,
                                                          metricsSubmitter: self.submitter,
                                                          subscriptionConfig: subConfig,
                                                          granularMetrics: self.influxConfig.value.granular,
                                                          engine: self.engine,
                                                          participantId: ourParticipantId,
                                                          joinDate: self.joinDate,
                                                          activeSpeakerStats: self.activeSpeakerStats,
                                                          controller: controller,
                                                          verbose: self.verbose,
                                                          startingGroup: startingGroupId,
                                                          manualActiveSpeaker: playtime.playtime && playtime.manualActiveSpeaker,
                                                          sframeContext: self.receiveContext,
                                                          calculateLatency: self.showLabels,
                                                          mediaInterop: self.mediaInterop)
        } else {
            subscriptionFactory = nil
        }
        self.publicationFactory = publicationFactory
        self.subscriptionFactory = subscriptionFactory

        // Connect to the relay/server.
        do {
            try await controller.connect()
            self.relayId = controller.serverId
        } catch let error as MoqCallControllerError {
            switch error {
            case .connectionFailure(let status):
                Self.logger.error("Failed to connect relay: \(status)")
            default:
                Self.logger.error("Unhandled MoqCallControllerError")
            }
            return false
        } catch {
            Self.logger.error("MoqCallController failed due to unknown error: \(error.localizedDescription)")
            return false
        }

        // Inject the manifest in order to create publications & subscriptions.
        if make {
            // Publish.
            if let publicationFactory {
                for publication in manifest.publications {
                    do {
                        let created = try controller.publish(details: publication,
                                                             factory: publicationFactory,
                                                             codecFactory: CodecFactoryImpl())
                        for pub in created where pub.1 is TextPublication {
                            self.textPublication = (pub.1 as! TextPublication) // swiftlint:disable:this force_cast
                        }
                    } catch {
                        Self.logger.warning("[\(publication.sourceID)] Couldn't create publication: \(error.localizedDescription)")
                    }
                }
            }

            // Subscribe.
            if let subscriptionFactory {
                for subscription in manifest.subscriptions {
                    do {
                        let set = try controller.subscribeToSet(details: subscription,
                                                                factory: subscriptionFactory,
                                                                subscribeType: .subscribe)
                        if subscription.mediaType == ManifestMediaTypes.text.rawValue {
                            let handlers = set.getHandlers()
                            precondition(handlers.count == 1,
                                         "Text subscription should only have one handler")
                            precondition(handlers.first?.1 is MultipleCallbackSubscription,
                                         "Text subscription handler should be MultipleCallbackSubscription")
                            // swiftlint:disable:next force_cast
                            let sub = handlers.first!.1 as! MultipleCallbackSubscription
                            self.textSubscriptions?.addSubscription(sub)
                        }
                    } catch {
                        Self.logger.warning("[\(subscription.sourceID)] Couldn't create subscription: \(error.localizedDescription)")
                    }
                }

                // Active speaker handling.
                let notifier: ActiveSpeakerNotifier?
                if playtime.playtime && playtime.manualActiveSpeaker {
                    let manual = ManualActiveSpeaker()
                    self.manualActiveSpeaker = manual
                    notifier = manual
                } else if let real = subscriptionFactory.activeSpeakerNotifier {
                    notifier = real
                } else {
                    notifier = nil
                }
                if let notifier = notifier {
                    let videoSubscriptions = manifest.subscriptions.filter { $0.mediaType == ManifestMediaTypes.video.rawValue }
                    do {
                        self.activeSpeaker = try .init(notifier: notifier,
                                                       controller: controller,
                                                       videoSubscriptions: videoSubscriptions,
                                                       factory: subscriptionFactory,
                                                       participantId: manifest.participantId,
                                                       activeSpeakerStats: self.activeSpeakerStats,
                                                       pauseResume: self.subscriptionConfig.value.pauseResume)
                    } catch {
                        Self.logger.error("Failed to create active speaker controller: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Are we doing subscribe namespace?
        if self.subscribeNamespaceEnabled {
            do {
                let namespaceTuple = try JSONDecoder().decode([String].self, from: Data(self.subscribeNamespace.utf8))
                let acceptNamespace = try JSONDecoder().decode([String].self, from: Data(self.subscribeNamespaceAccept.utf8))
                self.subscriptionNamespaceAcceptParsed = acceptNamespace.map { .init($0.utf8) }
                controller.subscribeNamespace(namespaceTuple)
                Self.logger.info("Subscribed to namespace: \(namespaceTuple)")
            } catch {
                Self.logger.warning("Failed to parse subscribe namespace", alert: true)
            }
        }

        // Start audio media.
        if let engine = self.engine {
            do {
                if make && self.role != .subscriber {
                    engine.setMicrophoneCapture(true)
                }
                try engine.start()
                if self.role != .subscriber {
                    self.audioCapture = true
                }
            } catch {
                Self.logger.warning("Audio failure. Apple requires us to have an aggregate input AND output device")
            }
        }

        // Start video media.
        if let captureManager = self.captureManager,
           self.role != .subscriber {
            do {
                try captureManager.startCapturing()
                self.videoCapture = true
            } catch {
                Self.logger.warning("Camera failure", alert: true)
            }
        }
        return true
    }

    func setManualActiveSpeaker(_ json: String) {
        guard json.count > 0 else { return }
        guard let data = json.data(using: .ascii),
              let speakers = try? JSONDecoder().decode([ParticipantId].self, from: data) else {
            Self.logger.error("Bad speaker JSON: \(json)")
            return
        }
        self.manualActiveSpeaker!.setActiveSpeakers(.init(speakers))
    }

    private func makeCallController(overrideNamespace: [String]?) -> MoqCallController {
        let endpointId: String = config.email
        let qLogPath: URL
        #if targetEnvironment(macCatalyst) || os(macOS)
        qLogPath = .downloadsDirectory
        #else
        qLogPath = .documentsDirectory
        #endif
        let subConfig = self.subscriptionConfig.value
        return qLogPath.path.withCString { qLogPath in
            let tConfig = TransportConfig(tls_cert_filename: nil,
                                          tls_key_filename: nil,
                                          time_queue_init_queue_size: 1000 * 150,
                                          time_queue_max_duration: 5000 * 150,
                                          time_queue_bucket_interval: 1,
                                          time_queue_rx_size: UInt32(subConfig.timeQueueTTL),
                                          debug: true,
                                          quic_cwin_minimum: subConfig.quicCwinMinimumKiB * 1024,
                                          quic_wifi_shadow_rtt_us: 0,
                                          idle_timeout_ms: 15000,
                                          use_reset_wait_strategy: subConfig.useResetWaitCC,
                                          use_bbr: subConfig.useBBR,
                                          quic_qlog_path: subConfig.enableQlog ? qLogPath : nil,
                                          quic_priority_limit: subConfig.quicPriorityLimit,
                                          max_connections: 1,
                                          ssl_keylog: false,
                                          socket_buffer_size: 1_000_000)
            let config = ClientConfig(connectUri: self.config.address,
                                      endpointUri: endpointId,
                                      transportConfig: tConfig,
                                      metricsSampleMs: 0)
            let client = config.connectUri.withCString { connectUri in
                config.endpointUri.withCString { endpointId in
                    QClientObjC(config: .init(connectUri: connectUri,
                                              endpointId: endpointId,
                                              transportConfig: config.transportConfig,
                                              metricsSampleMs: config.metricsSampleMs))
                }
            }
            let publishReceived: MoqCallController.PublishReceivedCallback = { [weak self] connectionHandle, requestId, tfn, attributes in
                guard let self = self else { return }
                self.publishReceived(connectionHandle: connectionHandle,
                                     requestId: requestId,
                                     track: .init(tfn),
                                     attributes: attributes)
            }
            return .init(endpointUri: endpointId,
                         client: client,
                         submitter: self.submitter,
                         overrideNamespace: overrideNamespace,
                         publishReceived: publishReceived) { [weak self] in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.onLeave()
                }
            }
        }
    }

    func leave() async {
        // Submit all pending metrics.
        await submitter?.submit()

        do {
            if self.videoCapture {
                try captureManager?.stopCapturing()
                self.videoCapture = false
            }
            if self.audioCapture {
                try engine?.stop()
                self.audioCapture = false
            }
            if let recorder = self.appRecorder {
                try await recorder.stopCapture()
            }
        } catch {
            Self.logger.error("Error while stopping media: \(error)")
        }

        // Disconnect based on which stack is in use
        if let moxygenClient = self.moxygenClient {
            moxygenClient.disconnect()
            self.moxygenClient = nil
            self.moxygenCallbacks = nil
        }

        do {
            try controller?.disconnect()
        } catch {
            Self.logger.error("Error while leaving call: \(error)")
        }
    }

    private func doMetrics(_ tags: [String: String]) {
        let token: String
        do {
            // Try and get metrics from storage.
            let storage = TokenStorage(tag: InfluxSettingsView.defaultsKey)
            if let fetched = try storage.retrieve() {
                token = fetched
                Self.logger.debug("Resolved influx token from keychain")
            } else {
                // Fetch from plist in this case.
                let defaultValue = try InfluxSettingsView.tokenFromPlist()
                try storage.store(defaultValue)
                token = defaultValue
                Self.logger.debug("Resolved influx token from default")
            }
        } catch {
            Self.logger.warning("Failed to fetch metrics credentials", alert: true)
            return
        }

        let influx = InfluxMetricsSubmitter(token: token,
                                            config: influxConfig.value,
                                            tags: tags)
        submitter = influx
        #if os(macOS)
        self.wlan = try? .init(submitter: influx)
        #endif
        if self.showLabels {
            self.activeSpeakerStats = .init(influx)
        }
        let measurement = _Measurement()
        self.measurement = .init(measurement: measurement, submitter: influx)
        if influxConfig.value.realtime {
            // Application metrics timer.
            self.appMetricTimer = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let duration: TimeInterval
                    if let self = self {
                        duration = TimeInterval(self.influxConfig.value.intervalSecs)
                        let usage = try cpuUsage()
                        await self.measurement?.measurement.recordCpuUsage(cpuUsage: usage, timestamp: Date.now)
                        await self.submitter?.submit()
                    } else {
                        return
                    }
                    try? await Task.sleep(for: .seconds(duration), tolerance: .seconds(duration), clock: .continuous)
                }
            }
        }
    }

    static func validateNamespace(_ namespace: String, placeholder: Bool) -> (namespace: [String]?, error: String?) {
        do {
            let decoded = try JSONDecoder().decode([String].self,
                                                   from: .init(namespace.utf8))
            guard placeholder else {
                return (decoded, nil)
            }
            var found = false
            for item in decoded {
                found = found || item.contains(CallState.namespaceSourcePlaceholder)
            }
            guard found else {
                return (nil, "Namespace must contain \(CallState.namespaceSourcePlaceholder) placeholder")
            }
            return (decoded, nil)
        } catch {
            guard placeholder else {
                return (nil, "Namespace must be valid JSON array")
            }
            return (nil, "Namespace must be valid JSON array with \(CallState.namespaceSourcePlaceholder) placeholder")
        }
    }

    func getManifestSubscriptions() -> [ManifestSubscription] {
        guard let currentManifest else { return [] }
        guard let resolvedNamespace else { return currentManifest.subscriptions }

        var subscriptions: [ManifestSubscription] = []
        for sub in currentManifest.subscriptions {
            var newProfiles: [Profile] = []
            var count = 0
            for profile in sub.profileSet.profiles {
                newProfiles.append(profile.transformNamespace(overrideNamespace: resolvedNamespace,
                                                              sourceId: sub.sourceID,
                                                              count: count))
                count += 1
            }
            subscriptions.append(.init(mediaType: sub.mediaType,
                                       sourceName: sub.sourceName,
                                       sourceID: sub.sourceID,
                                       label: sub.label,
                                       participantId: sub.participantId,
                                       profileSet: .init(type: sub.profileSet.type, profiles: newProfiles)))
        }
        return subscriptions
    }

    // swiftlint:disable:next function_body_length
    private func publishReceived(connectionHandle: UInt64,
                                 requestId: UInt64,
                                 track: FullTrackName,
                                 attributes: QPublishAttributes) {
        let controller = self.controller!
        var responseAccept = false
        var responseAttributes = QPublishAttributes()
        // We MUST resolve one way or the other.
        defer {
            self.controller?.resolvePublish(connectionHandle: connectionHandle,
                                            requestId: requestId,
                                            attributes: responseAttributes,
                                            tfn: track,
                                            response: .init(ok: responseAccept))
        }

        // Collect everything we need.
        let mediaIndex = 3
        let endpointIndex = 4
        guard let accept = self.subscriptionNamespaceAcceptParsed,
              track.matchesPrefix(prefix: accept),
              track.nameSpace.count >= endpointIndex - 1,
              let mediaType = String(data: track.nameSpace[mediaIndex], encoding: .utf8),
              let config = mediaType.firstMatch(of: #/\[(.*?)\]/#),
              let endpointIdString = String(data: track.nameSpace[endpointIndex], encoding: .utf8),
              let endpointMatch = endpointIdString.firstMatch(of: #/endpoint=(\d+)/#),
              let endpointId = Int(endpointMatch.1),
              let factory = self.subscriptionFactory else {
            Self.logger.warning("[\(track)] Declining offered publish")
            return
        }

        // Build the profile from the namespace as best we can.
        // TODO: We need to source expiry and priority here.
        let qualityProfile = String(config.1)
        let configParse = CodecFactoryImpl()
        let codecConfig = configParse.makeCodecConfig(from: qualityProfile, bitrateType: .average)
        let profile = Profile(qualityProfile: qualityProfile,
                              expiry: nil,
                              priorities: nil,
                              namespace: track.nameSpace.compactMap { String(data: $0, encoding: .utf8) },
                              channel: nil)
        let sourceId = "\(endpointId)_\(codecConfig.codec)"
        let manifestSubscription = ManifestSubscription(mediaType: "published",
                                                        sourceName: "published",
                                                        sourceID: sourceId,
                                                        label: "Published",
                                                        participantId: .init(UInt32(endpointId)),
                                                        profileSet: .init(type: "video",
                                                                          profiles: [profile]))

        // We need a destination for this media, and we only have the FTN to work it out.
        Self.logger.info("[\(track)] Accepting offered publish: \(profile)")

        // Need a set for this if we don't have one already.
        let publisherInitiated = MoqCallController.PublisherInitiatedDetails(trackAlias: attributes.trackAlias,
                                                                             requestId: requestId)

        do {
            if let existing = controller.getSubscriptionSet(sourceId) {
                try controller.subscribe(set: existing,
                                         profile: profile,
                                         factory: factory,
                                         publisherInitiated: publisherInitiated)
            } else {
                // Make one.
                try controller.subscribeToSet(details: manifestSubscription,
                                              factory: factory,
                                              subscribeType: .publisherInitiated(publisherInitiated))
            }
        } catch {
            Self.logger.error("Failed to create subscription handler for publish: \(error.localizedDescription)")
            return
        }

        // Let defer block accept.
        responseAccept = true
        responseAttributes = .init(priority: UInt8(profile.priorities?.first ?? 0),
                                   groupOrder: .originalPublisherOrder,
                                   deliveryTimeoutMs: UInt64(profile.expiry?.first ?? 0),
                                   filterType: .latestObject,
                                   forward: 1,
                                   newGroupRequestId: 0,
                                   isPublisherInitiated: true,
                                   trackAlias: attributes.trackAlias,
                                   dynamicGroups: attributes.dynamicGroups)
    }
}

// Metrics.
extension CallState {
    private actor _Measurement: Measurement {
        let id = UUID()
        var name: String = "ApplicationMetrics"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        func recordCpuUsage(cpuUsage: Double, timestamp: Date?) {
            record(field: "cpuUsage", value: cpuUsage as AnyObject, timestamp: timestamp)
        }
    }
}

// Moxygen callback handler with async connection support
class MoxygenCallbackHandler: NSObject, MoxygenClientCallbacks {
    private static let logger = DecimusLogger(MoxygenCallbackHandler.self)

    private var connectionContinuation: CheckedContinuation<Bool, Never>?
    private var lastError: String?

    /// Called when a subscriber connects to one of our published tracks
    var onSubscriberConnectedHandler: (([String], String) -> Void)?

    func onStatusChanged(_ status: MoxygenConnectionStatus) {
        let statusString: String
        switch status {
        case .disconnected: statusString = "Disconnected"
        case .connecting: statusString = "Connecting"
        case .connected: statusString = "Connected"
        case .failed: statusString = "Failed"
        @unknown default: statusString = "Unknown"
        }
        Self.logger.info("Moxygen status: \(statusString)")

        // Resume continuation if waiting for connection result
        if status == .connected {
            connectionContinuation?.resume(returning: true)
            connectionContinuation = nil
        } else if status == .failed {
            connectionContinuation?.resume(returning: false)
            connectionContinuation = nil
        }
    }

    func onError(_ error: String) {
        Self.logger.error("Moxygen error: \(error)")
        lastError = error
    }

    func onSubscriberConnected(_ trackNamespace: [String], trackName: String) {
        Self.logger.info("Moxygen: Subscriber connected to \(trackNamespace.joined(separator: "/"))/\(trackName)")
        onSubscriberConnectedHandler?(trackNamespace, trackName)
    }

    /// Await connection result. Call this after calling connect() on the client.
    func awaitConnection() async -> Bool {
        await withCheckedContinuation { continuation in
            self.connectionContinuation = continuation
        }
    }

    /// Get the last error message, if any.
    func getLastError() -> String? {
        lastError
    }
}


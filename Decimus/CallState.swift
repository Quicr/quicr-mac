// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

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

    // Demo.
    @AppStorage(SettingsView.demoEnabledKey)
    private var demoEnabled = false
    @AppStorage(SettingsView.demoMeetingIdKey)
    private var demoMeetingId: String = "demo-meeting-1"
    private var demoNamespaceHandlers: [QSubscribeNamespaceHandler] = []

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
                                                        useAnnounce: subConfig.useAnnounce,
                                                        demoEnabled: self.demoEnabled)
        } else {
            publicationFactory = nil
        }
        let playtime = self.playtimeConfig.value
        let ourParticipantId = (playtime.playtime && playtime.echo) ? nil : manifest.participantId
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

        // Demo namespace subscriptions — registered before publications so the relay
        // can match incoming publishes against the namespace prefix immediately.
        if self.demoEnabled, self.subscriptionFactory != nil {
            let meetingId = self.demoMeetingId
            let ownClientId = "\(manifest.participantId.aggregate)"
            let audioPrefix: [Data] = ["meetings.wbx.com", meetingId, "audio"].map { .init($0.utf8) }
            let videoPrefix: [Data] = ["meetings.wbx.com", meetingId, "video"].map { .init($0.utf8) }

            for (mediaType, prefix) in [("audio", audioPrefix), ("video", videoPrefix)] {
                let handler = QSubscribeNamespaceHandler(
                    namespacePrefix: prefix,
                    statusChangedCallback: { status, errorCode, namespacePrefix in
                        let namespace = namespacePrefix.compactMap { String(data: $0, encoding: .utf8) }
                        Self.logger.info("[demo/\(mediaType)] Subscribe namespace status: \(status), error: \(errorCode), prefix: \(namespace)")
                    },
                    trackAcceptableCallback: { [weak self] fullTrackName in
                        guard self != nil else { return false }
                        // Reject our own tracks.
                        if fullTrackName.nameSpace.count >= 4,
                           let remoteClientId = String(data: fullTrackName.nameSpace[3], encoding: .utf8),
                           remoteClientId == ownClientId {
                            Self.logger.info("[demo/\(mediaType)] Rejecting own track: \(fullTrackName)")
                            return false
                        }
                        Self.logger.info("[demo/\(mediaType)] Accepting track: \(fullTrackName)")
                        return true
                    },
                    createHandlerCallback: { [weak self] fullTrackName, trackAlias, priority, groupOrder, filterType in
                        guard let self else { return nil }
                        return self.demoCreateHandler(fullTrackName: fullTrackName,
                                                      trackAlias: trackAlias,
                                                      priority: priority,
                                                      groupOrder: groupOrder,
                                                      filterType: filterType)
                    })
                do {
                    try controller.subscribeNamespace(handler)
                    self.demoNamespaceHandlers.append(handler)
                    Self.logger.info("[demo] Subscribed to \(mediaType) namespace prefix: \(prefix.compactMap { String(data: $0, encoding: .utf8) })")
                } catch {
                    Self.logger.error("[demo] Failed to subscribe to \(mediaType) namespace: \(error.localizedDescription)")
                }
            }
        }

        // Inject the manifest in order to create publications & subscriptions.
        if make {
            if self.demoEnabled {
                // Demo mode: publish to hardcoded namespaces, skip manifest subscriptions.
                if let publicationFactory {
                    let meetingId = self.demoMeetingId
                    let userId = "\(manifest.participantId.aggregate)"
                    let demoPublications = Self.makeDemoPublications(meetingId: meetingId, userId: userId)
                    for publication in demoPublications {
                        do {
                            _ = try controller.publish(details: publication,
                                                       factory: publicationFactory,
                                                       codecFactory: CodecFactoryImpl())
                        } catch {
                            Self.logger.warning("[demo] [\(publication.sourceID)] Couldn't create publication: \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                // Normal mode: publish and subscribe from manifest.
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
        }

        // Are we doing subscribe namespace?
        if self.subscribeNamespaceEnabled {
            if let namespaceTuple = try? JSONDecoder().decode([String].self, from: Data(self.subscribeNamespace.utf8)),
               let acceptNamespace = try? JSONDecoder().decode([String].self,
                                                               from: Data(self.subscribeNamespaceAccept.utf8)) {
                self.subscriptionNamespaceAcceptParsed = acceptNamespace.map { .init($0.utf8) }
                let handler = QSubscribeNamespaceHandler(namespacePrefix: namespaceTuple.map { .init($0.utf8) },
                                                         statusChangedCallback: { status, errorCode, namespacePrefix in
                                                            // Status changed.
                                                            let namespace = namespacePrefix.compactMap { String(data: $0, encoding: .utf8) }
                                                            Self.logger.info("[\(namespace)] Subscribe namespace status changed: \(status), errorCode: \(errorCode)")
                                                         }, trackAcceptableCallback: {[weak self] fullTrackName in
                                                            // Do we want this track?
                                                            guard let self,
                                                                  let accept = self.subscriptionNamespaceAcceptParsed else {
                                                                Self.logger.warning("[\(fullTrackName)] Declining offered track: missing accept prefix")
                                                                return false
                                                            }
                                                            let acceptable = fullTrackName.matchesPrefix(prefix: accept)
                                                            Self.logger.info("[\(fullTrackName)] Offered track acceptable: \(acceptable)")
                                                            return acceptable
                                                         })
                do {
                    try controller.subscribeNamespace(handler)
                    Self.logger.info("Subscribed to namespace: \(namespaceTuple)")
                } catch {
                    Self.logger.error("Failed to subscribe to namespace: \(namespaceTuple): \(error.localizedDescription)")
                }
            } else {
                Self.logger.error("Bad subscribe namespace tuple JSON in settings")
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

// Demo.
extension CallState {
    /// Create a subscription handler for an accepted demo track via the namespace handler's CreateHandler.
    func demoCreateHandler(fullTrackName: FullTrackName,
                           trackAlias: UInt64,
                           priority: UInt8,
                           groupOrder: QGroupOrder,
                           filterType: QFilterType) -> QSubscribeTrackHandlerObjC? {
        guard let factory = self.subscriptionFactory,
              let controller = self.controller,
              let relayId = controller.serverId else { return nil }
        let endpointId = self.config.email

        let namespace = fullTrackName.nameSpace.compactMap { String(data: $0, encoding: .utf8) }
        guard namespace.count >= 4, namespace.first == "meetings.wbx.com" else {
            Self.logger.warning("[demo] Unexpected namespace format in CreateHandler: \(fullTrackName)")
            return nil
        }

        let mediaType = namespace[2]
        let remoteClientId = namespace[3]

        let qualityProfile: String
        let profileType: String
        switch mediaType {
        case "audio":
            qualityProfile = "opus,br=24"
            profileType = "audio"
        case "video":
            qualityProfile = "h264,width=1920,height=1080,fps=30,br=4000"
            profileType = "video"
        default:
            Self.logger.warning("[demo] Unknown media type in CreateHandler: \(mediaType)")
            return nil
        }

        let profile = Profile(qualityProfile: qualityProfile,
                              expiry: nil,
                              priorities: nil,
                              namespace: namespace,
                              channel: nil)
        let sourceId = "demo_\(remoteClientId)_\(mediaType)"
        let participantHash = remoteClientId.hashValue
        let manifestSubscription = ManifestSubscription(
            mediaType: mediaType,
            sourceName: String(data: fullTrackName.name, encoding: .utf8) ?? "",
            sourceID: sourceId,
            label: "Demo \(mediaType) \(remoteClientId)",
            participantId: .init(UInt32(abs(participantHash) % Int(UInt32.max))),
            profileSet: .init(type: profileType, profiles: [profile]))

        do {
            let set: SubscriptionSet
            if let existing = controller.getSubscriptionSet(sourceId) {
                set = existing
            } else {
                set = try factory.create(subscription: manifestSubscription,
                                         codecFactory: CodecFactoryImpl(),
                                         endpointId: endpointId,
                                         relayId: relayId)
                controller.storeSubscriptionSet(sourceId: sourceId, set: set)
            }

            let subscription = try factory.create(set: set,
                                                  profile: profile,
                                                  codecFactory: CodecFactoryImpl(),
                                                  endpointId: endpointId,
                                                  relayId: relayId,
                                                  publisherInitiated: true)
            try set.addHandler(subscription)
            // Do NOT call controller.subscribeTrack — AcceptNewTrack handles transport registration.
            Self.logger.info("[demo] Created \(mediaType) subscription for \(remoteClientId) via CreateHandler")
            return subscription
        } catch {
            Self.logger.error("[demo] Failed to create subscription in CreateHandler: \(error.localizedDescription)")
            return nil
        }
    }

    /// Build synthetic ManifestPublication entries for demo mode.
    static func makeDemoPublications(meetingId: String, userId: String) -> [ManifestPublication] {
        let audioNamespace = ["meetings.wbx.com", meetingId, "audio", userId]
        let audioProfile = Profile(qualityProfile: "opus,br=24",
                                   expiry: [1000],
                                   priorities: [0],
                                   namespace: audioNamespace,
                                   name: "opus_48khz")
        let audioPublication = ManifestPublication(mediaType: "audio",
                                                   sourceName: "microphone",
                                                   sourceID: "demo_audio",
                                                   label: "Demo Audio",
                                                   profileSet: .init(type: "audio",
                                                                     profiles: [audioProfile]))

        let videoNamespace = ["meetings.wbx.com", meetingId, "video", userId]
        let videoProfile = Profile(qualityProfile: "h264,width=1920,height=1080,fps=30,br=4000",
                                   expiry: [1000, 200],
                                   priorities: [0, 1],
                                   namespace: videoNamespace,
                                   name: "h264")
        let videoPublication = ManifestPublication(mediaType: "video",
                                                   sourceName: "camera",
                                                   sourceID: "demo_video",
                                                   label: "Demo Video",
                                                   profileSet: .init(type: "video",
                                                                     profiles: [videoProfile]))

        return [audioPublication, videoPublication]
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

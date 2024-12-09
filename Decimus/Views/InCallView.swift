// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import os

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    /// Supported supported video layouts.
    enum VideoLayout: CaseIterable, CustomStringConvertible {
        /// A 1x1 grid (of the active speaker, if known).
        case oneByOne
        /// A 2x2 grid (ranked by speaker, if known).
        case twoByTwo
        /// A unlimited grid (ranked by speaker, if known).
        case nByN
        /// A film strip of large active speaker and small others at top.
        case filmStrip

        var description: String {
            switch self {
            case .oneByOne:
                "1x1"
            case .twoByTwo:
                "2x2"
            case .nByN:
                "Grid"
            case .filmStrip:
                "Film Strip"
            }
        }

        /// The number of participants to show in this layout.
        var count: Int? {
            switch self {
            case .oneByOne:
                1
            case .twoByTwo:
                4
            default:
                nil
            }
        }
    }

    @StateObject var viewModel: ViewModel
    @State private var leaving: Bool = false
    @State private var connecting: Bool = false
    @State private var noParticipantsDetected = false
    @State private var showPreview = true
    @State private var lastTap: Date = .now
    @State private var debugDetail = false
    @State private var layout = VideoLayout.nByN
    @State private var activeSpeakers: String = ""
    var noParticipants: Bool {
        self.viewModel.videoParticipants.participants.isEmpty
    }
    @State private var showControls = false

    /// Callback when call is left.
    private let onLeave: () -> Void
    #if !os(tvOS) && !os(macOS)
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()
    #endif

    init(config: CallConfig, onLeave: @escaping () -> Void) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        self.onLeave = onLeave
        _viewModel = .init(wrappedValue: .init(config: config, onLeave: onLeave))
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                Group {
                    let gridCount: Int? = switch self.layout {
                    case .oneByOne:
                        1
                    case .twoByTwo:
                        4
                    default:
                        nil
                    }
                    #if os(tvOS)
                    ZStack {
                        // Incoming videos.
                        VideoGrid(showLabels: self.viewModel.showLabels,
                                  connecting: self.$connecting,
                                  blur: self.$showControls,
                                  restrictedCount: gridCount,
                                  videoParticipants: self.viewModel.videoParticipants)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        HStack {
                            if self.showControls {
                                Group {
                                    Button("Hide Controls") {
                                        self.showControls = false
                                    }
                                    Button("Toggle Debug Details") {
                                        self.debugDetail = true
                                    }
                                    // Call controls panel.
                                    CallControls(captureManager: self.viewModel.captureManager,
                                                 engine: self.viewModel.engine,
                                                 leaving: self.$leaving)
                                }
                            } else {
                                Spacer()
                                VStack {
                                    Button("Show Controls") {
                                        self.showControls = true
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .disabled(self.leaving)
                    }
                    #else
                    VStack {
                        VideoGrid(showLabels: self.viewModel.showLabels,
                                  connecting: self.$connecting,
                                  blur: .constant(false),
                                  restrictedCount: gridCount,
                                  videoParticipants: self.viewModel.videoParticipants)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        Button("Toggle Debug Details") {
                            self.debugDetail = true
                        }

                        // Call controls panel.
                        CallControls(captureManager: viewModel.captureManager,
                                     engine: viewModel.engine,
                                     leaving: $leaving)
                            .disabled(leaving)
                            .padding(.bottom)
                            .frame(alignment: .top)
                    }
                    #endif
                }
                .sheet(isPresented: self.$debugDetail) {
                    VStack {
                        if let controller = self.viewModel.controller,
                           let manifest = self.viewModel.currentManifest {
                            Text("Debug Details").font(.title)
                            Form {
                                HStack {
                                    Text("Relay")
                                    Text(controller.serverId ?? "Unknown").monospaced()
                                }
                                LabeledContent("Layout") {
                                    Picker("Layout", selection: self.$layout) {
                                        ForEach(VideoLayout.allCases, id: \.self) { layout in
                                            Text("\(layout)")
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                }
                                let playtime = self.viewModel.playtimeConfig.value
                                if playtime.playtime && playtime.manualActiveSpeaker {
                                    LabeledContent("Active Speakers") {
                                        HStack {
                                            TextField("Active Speakers",
                                                      text: self.$activeSpeakers)
                                            #if !os(macOS)
                                            .keyboardType(.asciiCapable)
                                            #endif
                                            Button("Set") { self.viewModel.setManualActiveSpeaker(self.activeSpeakers)
                                            }
                                        }
                                    }
                                }
                            }
                            ScrollView {
                                SubscriptionPopover(controller, manifest: manifest, factory: self.viewModel.subscriptionFactory!)
                                PublicationPopover(controller)
                            }
                        }
                    }.padding()
                    Spacer()
                    Button("Done") {
                        self.debugDetail = false
                    }.padding()
                }

                // Preview / self-view.
                // swiftlint:disable force_try
                if let capture = viewModel.captureManager,
                   let camera = try! capture.activeDevices().first,
                   showPreview {
                    let gWidth = geometry.size.width
                    let gHeight = geometry.size.height
                    let cWidth = gWidth / 7
                    let cHeight = gHeight / 7
                    let pWidth = cWidth / 10
                    let pHeight = cHeight / 10
                    try! PreviewView(captureManager: capture, device: camera)
                        .frame(maxWidth: cWidth)
                        .offset(CGSize(width: gWidth - cWidth - pWidth,
                                       height: gHeight / 2 - (cHeight * 0.75) - pHeight))
                }
                // swiftlint:enable force_try
            }

            if leaving {
                LeaveModal(leaveAction: {
                    await viewModel.leave()
                    onLeave()
                }, cancelAction: leaving = false)
                .frame(maxWidth: 400, alignment: .center)
            }
        }
        .background(.black)
        .onChange(of: noParticipants) { _, newValue in
            noParticipantsDetected = newValue
        }
        .onChange(of: self.layout) {
            if let activeSpeaker = self.viewModel.activeSpeaker {
                activeSpeaker.setClampCount(self.layout.count)
            }
        }
        .task {
            connecting = true
            guard await viewModel.join() else {
                await viewModel.leave()
                return onLeave()
            }
            connecting = false
        }.onTapGesture {
            // Show the preview when we tap.
            self.lastTap = .now
            withAnimation {
                self.showPreview.toggle()
            }
        }
        .task {
            // Hide the preview if we didn't tap for a while.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }

                if self.lastTap.timeIntervalSince(.now) < -5 {
                    withAnimation {
                        if self.showPreview {
                            self.showPreview = false
                        }
                    }
                }
            }
        }
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        private static let logger = DecimusLogger(InCallView.ViewModel.self)

        let engine: DecimusAudioEngine?
        private(set) var controller: MoqCallController?
        private(set) var activeSpeaker: ActiveSpeakerApply<VideoSubscription>?
        private(set) var manualActiveSpeaker: ManualActiveSpeaker?
        private(set) var captureManager: CaptureManager?
        private(set) var videoParticipants = VideoParticipants()
        private(set) var currentManifest: Manifest?
        private let config: CallConfig
        private var appMetricTimer: Task<(), Error>?
        private var measurement: MeasurementRegistration<_Measurement>?
        private var submitter: MetricsSubmitter?
        private var audioCapture = false
        private var videoCapture = false
        private let onLeave: () -> Void
        var relayId: String?
        private(set) var publicationFactory: PublicationFactory?
        private(set) var subscriptionFactory: SubscriptionFactoryImpl?

        @AppStorage(SubscriptionSettingsView.showLabelsKey)
        var showLabels: Bool = true

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        @AppStorage("subscriptionConfig")
        private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

        @AppStorage(PlaytimeSettingsView.defaultsKey)
        private(set) var playtimeConfig: AppStorageWrapper<PlaytimeSettings> = .init(value: .init())

        init(config: CallConfig, onLeave: @escaping () -> Void) {
            self.config = config
            self.onLeave = onLeave
            do {
                self.engine = try .init()
            } catch {
                Self.logger.error("Failed to create AudioEngine: \(error.localizedDescription)")
                self.engine = nil
            }

            if influxConfig.value.submit {
                let tags: [String: String] = [
                    "relay": "\(config.address):\(config.port)",
                    "email": config.email,
                    "conference": "\(config.conferenceID)",
                    "protocol": "\(config.connectionProtocol)"
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

        func join() async -> Bool {
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

            // TODO: Doesn't need to be this defensive.
            guard let captureManager = self.captureManager,
                  let engine = self.engine else {
                return false
            }

            // Create the factories now that we have the participant ID.
            let publicationFactory = PublicationFactoryImpl(opusWindowSize: self.subscriptionConfig.value.opusWindowSize,
                                                            reliability: self.subscriptionConfig.value.mediaReliability,
                                                            engine: engine,
                                                            metricsSubmitter: self.submitter,
                                                            granularMetrics: self.influxConfig.value.granular,
                                                            captureManager: captureManager,
                                                            participantId: manifest.participantId,
                                                            keyFrameInterval: self.subscriptionConfig.value.keyFrameInterval)
            let playtime = self.playtimeConfig.value
            let ourParticipantId = (playtime.playtime && playtime.echo) ? nil : manifest.participantId
            let subscriptionFactory = SubscriptionFactoryImpl(videoParticipants: self.videoParticipants,
                                                              metricsSubmitter: self.submitter,
                                                              subscriptionConfig: self.subscriptionConfig.value,
                                                              granularMetrics: self.influxConfig.value.granular,
                                                              engine: engine,
                                                              participantId: ourParticipantId)
            self.publicationFactory = publicationFactory
            self.subscriptionFactory = subscriptionFactory
            let controller = self.makeCallController()
            self.controller = controller

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
            do {
                // Publish.
                for publication in manifest.publications {
                    try controller.publish(details: publication, factory: publicationFactory, codecFactory: CodecFactoryImpl())
                }

                // Subscribe.
                for subscription in manifest.subscriptions {
                    _ = try controller.subscribeToSet(details: subscription, factory: subscriptionFactory, subscribe: true)
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
                    self.activeSpeaker = try .init(notifier: notifier,
                                                   controller: controller,
                                                   videoSubscriptions: videoSubscriptions,
                                                   factory: subscriptionFactory,
                                                   participantId: manifest.participantId)
                }
            } catch {
                Self.logger.error("Failed to set manifest: \(error.localizedDescription)")
                return false
            }

            // Start audio media.
            do {
                try engine.start()
                self.audioCapture = true
            } catch {
                Self.logger.warning("Audio failure. Apple requires us to have an aggregate input AND output device", alert: true)
            }

            // Start video media.
            do {
                try captureManager.startCapturing()
                self.videoCapture = true
            } catch {
                Self.logger.warning("Camera failure", alert: true)
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

        private func makeCallController() -> MoqCallController {
            let connectUri: String = "moq://\(config.address):\(config.port)"
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
                                              time_queue_init_queue_size: 1000,
                                              time_queue_max_duration: 5000,
                                              time_queue_bucket_interval: 1,
                                              time_queue_rx_size: UInt32(subConfig.timeQueueTTL),
                                              debug: true,
                                              quic_cwin_minimum: subConfig.quicCwinMinimumKiB * 1024,
                                              quic_wifi_shadow_rtt_us: 0,
                                              pacing_decrease_threshold_Bps: 16000,
                                              pacing_increase_threshold_Bps: 16000,
                                              idle_timeout_ms: 15000,
                                              use_reset_wait_strategy: subConfig.useResetWaitCC,
                                              use_bbr: subConfig.useBBR,
                                              quic_qlog_path: subConfig.enableQlog ? qLogPath : nil,
                                              quic_priority_limit: subConfig.quicPriorityLimit)
                let config = ClientConfig(connectUri: connectUri,
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
                return .init(endpointUri: endpointId,
                             client: client,
                             submitter: self.submitter) { [weak self] in
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
                let storage = try TokenStorage(tag: InfluxSettingsView.defaultsKey)
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
    }
}

// Metrics.
extension InCallView.ViewModel {
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

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(config: .init(address: "127.0.0.1",
                                 port: 5001,
                                 connectionProtocol: .QUIC)) { }
    }
}

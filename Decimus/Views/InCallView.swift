import SwiftUI
import AVFoundation
import UIKit
import os

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    @StateObject var viewModel: ViewModel
    @State private var leaving: Bool = false
    @State private var connecting: Bool = false
    @State private var noParticipantsDetected = false
    var noParticipants: Bool {
        viewModel.controller?.subscriberDelegate.participants.participants.isEmpty ?? true
    }

    /// Callback when call is left.
    private let onLeave: () -> Void
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    init(config: CallConfig, onLeave: @escaping () -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.onLeave = onLeave
        _viewModel = .init(wrappedValue: .init(config: config))
    }

    var body: some View {
        ZStack {
            VStack {
                if connecting || noParticipantsDetected {
                    ZStack {
                        Image("RTMC-Background")
                            .resizable()
                            .frame(maxHeight: .infinity,
                                   alignment: .center)
                            .cornerRadius(12)
                            .padding([.horizontal, .bottom])
                        if connecting {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                    }
                } else {
                    if let controller = viewModel.controller {
                        VideoGrid(participants: controller.subscriberDelegate.participants)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }

                if let capture = viewModel.captureManager {
                    CallControls(captureManager: capture,
                                 engine: viewModel.engine,
                                 leaving: $leaving)
                        .disabled(leaving)
                        .padding(.bottom)
                        .frame(alignment: .top)
                }
            }

            if leaving {
                LeaveModal(leaveAction: {
                    Task { await viewModel.leave() }
                    onLeave()
                }, cancelAction: leaving = false)
                .frame(maxWidth: 400, alignment: .center)
            }
        }
        .background(.black)
        .onChange(of: noParticipants) { newValue in
            noParticipantsDetected = newValue
        }
        .task {
            connecting = true
            guard await viewModel.join() else {
                await viewModel.leave()
                return onLeave()
            }
            connecting = false
        }
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        private static let logger = DecimusLogger(InCallView.ViewModel.self)

        let engine: AudioEngine
        private(set) var controller: CallController?
        private(set) var captureManager: CaptureManager?
        private let config: CallConfig
        private var appMetricTimer: Task<(), Error>?
        private var measurement: _Measurement?

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        @AppStorage("subscriptionConfig")
        private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

        init(config: CallConfig) {
            self.engine = try! .init()
            self.config = config
            let tags: [String: String] = [
                "relay": "\(config.address):\(config.port)",
                "email": config.email,
                "conference": "\(config.conferenceID)",
                "protocol": "\(config.connectionProtocol)"
            ]

            var submitter: MetricsSubmitter?
            if influxConfig.value.submit {
                let influx = InfluxMetricsSubmitter(config: influxConfig.value, tags: tags)
                submitter = influx
                self.measurement = .init(submitter: influx)
                Task {
                    await influx.startSubmitting(interval: influxConfig.value.intervalSecs)
                }

                // Application metrics timer.
                self.appMetricTimer = .init(priority: .utility) { [weak self] in
                    while !Task.isCancelled,
                          let self = self {
                        let usage = try cpuUsage()
                        await self.measurement?.recordCpuUsage(cpuUsage: usage, timestamp: Date.now)
                        try? await Task.sleep(for: .seconds(1), tolerance: .seconds(1))
                    }
                }
            } else {
                self.appMetricTimer = nil
                self.measurement = nil
            }

            do {
                self.captureManager = try .init(metricsSubmitter: submitter, granularMetrics: influxConfig.value.granular)
            } catch {
                Self.logger.error("Failed to create camera manager: \(error.localizedDescription)", alert: true)
                return
            }

            do {
                self.controller = try .init(metricsSubmitter: submitter,
                                            captureManager: captureManager!,
                                            config: subscriptionConfig.value,
                                            engine: engine,
                                            granularMetrics: influxConfig.value.granular)
            } catch {
                Self.logger.error("CallController failed: \(error.localizedDescription)", alert: true)
            }
        }

        func join() async -> Bool {
            do {
                try await self.controller?.connect(config: config)
                try captureManager?.startCapturing()
                return true
            } catch {
                Self.logger.error("Failed to connect to call: \(error.localizedDescription)", alert: true)
                return false
            }
        }

        func leave() async {
            do {
                try captureManager?.stopCapturing()
                try controller?.disconnect()
            } catch {
                Self.logger.error("Error while leaving call: \(error)", alert: true)
            }
        }
    }
}

// Metrics.
extension InCallView.ViewModel {
    private actor _Measurement: Measurement {
        var name: String = "ApplicationMetrics"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        init(submitter: MetricsSubmitter) {
            Task {
                await submitter.register(measurement: self)
            }
        }

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

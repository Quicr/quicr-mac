import SwiftUI
import AVFoundation
import UIKit

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    @StateObject var viewModel: ViewModel
    @State private var leaving: Bool = false
    @EnvironmentObject private var errorHandler: ObservableError
    private let errorWriter: ErrorWriter

    /// Callback when call is left.
    private let onLeave: () -> Void
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    init(errorWriter: ErrorWriter, config: CallConfig, onLeave: @escaping () -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.errorWriter = errorWriter
        self.onLeave = onLeave
        _viewModel = .init(wrappedValue: .init(errorHandler: errorWriter, config: config))
    }

    var body: some View {
        ZStack {
            VStack {
                VideoGrid(participants: viewModel.controller!.subscriberDelegate.participants)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                if let capture = viewModel.captureManager {
                    CallControls(errorWriter: errorWriter,
                                 captureManager: capture,
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

            ErrorView()
        }
        .background(.black)
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        private let errorHandler: ErrorWriter
        private(set) var controller: CallController?
        private(set) var captureManager: CaptureManager?

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        init(errorHandler: ErrorWriter, config: CallConfig) {
            let tags: [String: String] = [
                "relay": "\(config.address):\(config.port)",
                "email": config.email,
                "conference": "\(config.conferenceID)",
                "protocol": "\(config.connectionProtocol)"
            ]
            self.errorHandler = errorHandler
            do {
                self.captureManager = try .init()
            } catch {
                errorHandler.writeError("Failed to create camera manager: \(error.localizedDescription)")
                return
            }
            let submitter = InfluxMetricsSubmitter(config: influxConfig.value, tags: tags)
            Task {
                guard influxConfig.value.submit else { return }
                await submitter.startSubmitting(interval: influxConfig.value.intervalSecs)
            }

            self.controller = .init(errorWriter: errorHandler,
                                    metricsSubmitter: submitter,
                                    captureManager: captureManager!)
            Task {
                do {
                    try await self.controller!.connect(config: config)
                } catch {
                    errorHandler.writeError("Failed to connect to call: \(error.localizedDescription)")
                }
            }
        }

        func leave() async {
            do {
                try controller!.disconnect()
            } catch {
                errorHandler.writeError("Error while leaving call: \(error)")
            }
        }
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(errorWriter: ObservableError(),
                   config: .init(address: "127.0.0.1",
                                 port: 5001,
                                 connectionProtocol: .QUIC)) { }
            .environmentObject(ObservableError())
    }
}

import SwiftUI
import AVFoundation
import UIKit

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    @StateObject var viewModel: ViewModel
    @State private var leaving: Bool = false

    /// Callback when call is left.
    private let onLeave: () -> Void
#if !os(tvOS)
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()
#endif

    init(config: CallConfig, onLeave: @escaping () -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.onLeave = onLeave
        _viewModel = StateObject(wrappedValue: ViewModel(config: config))
    }

    var body: some View {
        ZStack {
            VStack {
                VideoGrid(participants: viewModel.controller!.subscriberDelegate.participants)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                CallControls(errorWriter: viewModel.errorHandler,
                             captureManager: viewModel.captureManager,
                             leaving: $leaving)
                    .disabled(leaving)
                    .padding(.bottom)
                    .frame(alignment: .top)
            }

            if leaving {
                LeaveModal(leaveAction: {
                    Task { await viewModel.leave() }
                    onLeave()
                }, cancelAction: leaving = false)
                    .frame(maxWidth: 400, alignment: .center)
            }

            ErrorView(errorHandler: viewModel.errorHandler)
        }
        .background(.black)
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        let errorHandler = ObservableError()
        private(set) var controller: CallController?
        private(set) var captureManager: CaptureManager

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        init(config: CallConfig) {
            let tags: [String: String] = [
                "relay": "\(config.address):\(config.port)",
                "email": config.email,
                "conference": "\(config.conferenceID)",
                "protocol": "\(config.connectionProtocol)"
            ]
            self.captureManager = .init(errorHandler: errorHandler)
            let submitter = InfluxMetricsSubmitter(config: influxConfig.value, tags: tags)
            Task {
                guard influxConfig.value.submit else { return }
                await submitter.startSubmitting(interval: influxConfig.value.intervalSecs)
            }

            self.controller = .init(errorWriter: errorHandler,
                                    metricsSubmitter: submitter,
                                    captureManager: captureManager,
                                    // TODO: inputAudioFormat needs to be the real input format.
                                    inputAudioFormat: AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                                    sampleRate: 48000,
                                                                    channels: 1,
                                                                    interleaved: true)!)
            do {
                Task { try await self.controller!.connect(config: config) }
            }
        }

        func leave() async {
            do {
                try controller!.disconnect()
            } catch {
                errorHandler.writeError(message: "Error while leaving call: \(error)")
            }
        }
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(config: .init(address: "127.0.0.1", port: 5001, connectionProtocol: .QUIC)) { }
    }
}

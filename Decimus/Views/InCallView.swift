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
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    init(config: CallConfig, onLeave: @escaping () -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.onLeave = onLeave
        _viewModel = StateObject(wrappedValue: ViewModel(config: config))
    }

    var body: some View {
        ZStack {
            VStack {
                VideoGrid(participants: viewModel.controller!.subscriber.participants)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                CallControls(errorWriter: viewModel.errorHandler, leaving: $leaving)
                    .disabled(leaving)
                    .padding(.bottom)
                    .frame(alignment: .top)
            }
            .edgesIgnoringSafeArea(.top) // Note: Only because of navigation bar forcing whole content down by 50

            if leaving {
                LeaveModal(leaveAction: onLeave, cancelAction: leaving = false)
                    .frame(maxWidth: 400, alignment: .center)
            }

            // Error messages.
            ErrorView(errorHandler: viewModel.errorHandler)
        }
        .background(.black)
        .onDisappear {
            Task {
                await viewModel.leave()
            }
        }
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        private(set) var errorHandler = ObservableError()
        private(set) var controller: CallController?

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        init(config: CallConfig) {
            let submitter = InfluxMetricsSubmitter(config: influxConfig.value)
            Task {
                guard influxConfig.value.submit else { return }
                await submitter.startSubmitting(interval: influxConfig.value.intervalSecs)
            }

            // TODO: inputAudioFormat needs to be the real input format.
            self.controller = .init(errorWriter: errorHandler,
                                    metricsSubmitter: submitter,
                                    inputAudioFormat: AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                                    sampleRate: 48000,
                                                                    channels: 1,
                                                                    interleaved: true)!)
            Task {
                do {
                    try await self.controller!.connect(config: config)
                }
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

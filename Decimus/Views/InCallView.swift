import SwiftUI
import AVFoundation
import UIKit

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    @StateObject var viewModel: ViewModel
    @State private var leaving: Bool = false
    @EnvironmentObject private var errorHandler: ObservableError

    /// Callback when call is left.
    private let onLeave: () -> Void
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    init(errorWriter: ErrorWriter, config: CallConfig, onLeave: @escaping () -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.onLeave = onLeave
        let model: ViewModel = .init(errorHandler: errorWriter, config: config)
        _viewModel = .init(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            VStack {
                VideoGrid(participants: viewModel.controller!.subscriberDelegate.participants)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                CallControls(errorWriter: errorHandler, leaving: $leaving)
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

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        init(errorHandler: ErrorWriter, config: CallConfig) {
            self.errorHandler = errorHandler
            let submitter = InfluxMetricsSubmitter(config: influxConfig.value)
            Task {
                guard influxConfig.value.submit else { return }
                await submitter.startSubmitting(interval: influxConfig.value.intervalSecs)
            }

            self.controller = .init(errorWriter: errorHandler,
                                    metricsSubmitter: submitter,
                                    // TODO: inputAudioFormat needs to be the real input format.
                                    inputAudioFormat: AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                                    sampleRate: 48000,
                                                                    channels: 1,
                                                                    interleaved: true)!)
            Task {
                do {
                    try await self.controller!.connect(config: config) }
                catch {
                    errorHandler.writeError("CallController failed: \(error.localizedDescription)")
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

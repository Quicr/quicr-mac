import SwiftUI
import AVFoundation
import UIKit

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView<Mode>: View where Mode: ApplicationMode {
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
                VideoGrid(participants: viewModel.mode!.participants)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                CallControls(leaving: $leaving)
                    .disabled(leaving)
                    .padding(.bottom)
                    .frame(alignment: .top)
            }
            .edgesIgnoringSafeArea(.top) // Note: Only because of navigation bar forcing whole content down by 50

            if leaving {
                LeaveModal(leaveAction: onLeave, cancelAction: { leaving = false })
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
        .environmentObject(viewModel.callController!)
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        private(set) var errorHandler = ObservableError()
        private(set) var mode: Mode?
        var callController: CallController?
        private var unitFactory: AudioUnitFactory?

        @AppStorage("playerType") private var playerType: Int = PlayerType.avAudioEngine.rawValue

        @AppStorage("influxConfig") private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        init(config: CallConfig) {
            let playerType: PlayerType = .init(rawValue: playerType)!
            let player = makeAudioPlayer(type: playerType)
            let submitter = InfluxMetricsSubmitter(config: influxConfig.value)
            Task {
                guard influxConfig.value.submit else { return }
                await submitter.startSubmitting(interval: influxConfig.value.intervalSecs)
            }
            // TODO: inputAudioFormat needs to be the real input format.
            self.mode = .init(errorWriter: errorHandler, player: player,
                              metricsSubmitter: submitter,
                              inputAudioFormat: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!,
                              outputAudioFormat: player.inputFormat)
            let capture: CaptureManager = .init(deviceChangeCallback: { [weak mode] device, event in
                                                    mode?.onDeviceChange(device: device, event: event)
                                                },
                                                errorHandler: errorHandler)
            self.callController = CallController(mode: mode!, capture: capture)
            Task {
                do {
                    try await self.mode!.connect(config: config)
                }
            }
        }

        func leave() async {
            await callController!.leave()
            do {
                try mode!.disconnect()
                if let factory = unitFactory {
                    try factory.clearIOUnit()
                }
            } catch {
                errorHandler.writeError(message: "Error while leaving call: \(error)")
            }
        }

        private func makeAudioPlayer(type: PlayerType) -> AudioPlayer {
            switch type {
            case .audioUnit:
                let unit: AudioUnit
                unitFactory = .init()
                do {
                    unit = try unitFactory!.makeIOUnit(voip: false)
                } catch {
                    errorHandler.writeError(message: "Failed to create IOAU")
                    return AVEngineAudioPlayer(errorWriter: errorHandler)
                }
                let auPlayer: AudioUnitPlayer
                do {
                    auPlayer = try .init(audioUnit: unit)
                } catch {
                    errorHandler.writeError(message: "Failed to create AudioUnitPlayer: \(error)")
                    return AVEngineAudioPlayer(errorWriter: errorHandler)
                }
                do {
                    try unit.initializeAndStart()
                } catch {
                    errorHandler.writeError(message: "Failed to initialize IOAU \(error)")
                }
                print("Using AudioUnitPlayer")
                return auPlayer
            case .avAudioEngine:
                print("Using AVEngineAudioPlayer")
                return AVEngineAudioPlayer(errorWriter: errorHandler)
            case .fasterAvAudioEngine:
                print("Using FasterAVAudioEnginePlayer")
                return FasterAVEngineAudioPlayer(errorWriter: errorHandler)
            }
        }
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(config: .init(address: "127.0.0.1", port: 5001, connectionProtocol: .QUIC)) { }
    }
}

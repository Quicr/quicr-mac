import SwiftUI
import AVFoundation
import UIKit

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView<Mode>: View where Mode: ApplicationModeBase {
    @StateObject var viewModel = ViewModel()
    @State private var leaving: Bool = false

    /// Callback when call is left.
    private let onLeave: () -> Void
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    init(onLeave: @escaping () -> Void = {}) {
        UIApplication.shared.isIdleTimerDisabled = true
        self.onLeave = onLeave
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
        .task {
            await viewModel.join()
        }
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
        @Published private(set) var errorHandler = ObservableError()
        @Published private(set) var mode: Mode?
        @Published var callController: CallController?

        @AppStorage("playerType") private var playerType: Int = PlayerType.avAudioEngine.rawValue

        init() {
            let player: AudioPlayer
            let playerType: PlayerType = .init(rawValue: playerType)!
            switch playerType {
            case .audioUnit:
                errorHandler.writeError(message: "AudioUnit player yet not implemented. Using AVEngineAudioPlayer.")
                player = AVEngineAudioPlayer(errorWriter: errorHandler)
            case .avAudioEngine:
                player = AVEngineAudioPlayer(errorWriter: errorHandler)
            }

            self.mode = .init(errorWriter: errorHandler, player: player)
            self.callController = CallController(mode: mode!, errorHandler: errorHandler)
        }

        func join() async {
            await callController!.join()
        }
        func leave() async {
            await callController!.leave()
        }
    }
}

extension InCallView where Mode == QMediaPubSub {
    init(config: CallConfig, onLeave: @escaping () -> Void) {
        self.init(onLeave: onLeave)
        _viewModel = StateObject(wrappedValue: ViewModel(config: config))
    }
}

extension InCallView.ViewModel where Mode == QMediaPubSub {
    convenience init(config: CallConfig) {
        self.init()
        do {
            try mode!.connect(config: config)
        } catch {
            self.errorHandler.writeError(message: "[QMediaPubSub] Already connected!")
        }
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView()
    }
}

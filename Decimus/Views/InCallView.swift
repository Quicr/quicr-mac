import SwiftUI
import AVFoundation
import UIKit

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    @StateObject var viewModel: ViewModel
    @State private var leaving: Bool = false
    @State private var connecting: Bool = false
    @State private var noParticipantsDetected = false
    var noParticipants: Bool {
        viewModel.controller!.subscriberDelegate.participants.participants.isEmpty
    }

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
                    VideoGrid(participants: viewModel.controller!.subscriberDelegate.participants)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }

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
        private let errorHandler: ErrorWriter
        private(set) var controller: CallController?
        private(set) var captureManager: CaptureManager?
        private let config: CallConfig
        private(set) var audioEngine: AVAudioEngine?

        @AppStorage("influxConfig")
        private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

        init(errorHandler: ErrorWriter, config: CallConfig) {
            self.config = config
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

            do {
                self.audioEngine = try setupAudioSession(voiceProcessing: true)
            } catch {
                errorHandler.writeError("Failed to create audio engine: \(error.localizedDescription)")
                return
            }

            self.controller = .init(errorWriter: errorHandler,
                                    metricsSubmitter: submitter,
                                    captureManager: captureManager!,
                                    engine: audioEngine!)
        }

        func join() async -> Bool {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                self.audioEngine?.prepare()
                try self.audioEngine?.start()
                try await self.controller!.connect(config: config)
                return true
            } catch {
                errorHandler.writeError("Failed to connect to call: \(error.localizedDescription)")
                return false
            }
        }

        func leave() {
            do {
                try AVAudioSession.sharedInstance().setActive(false)
                try controller!.disconnect()
                self.audioEngine?.stop()
            } catch {
                errorHandler.writeError("Error while leaving call: \(error)")
            }
        }

        private func setupAudioSession(voiceProcessing: Bool) throws -> AVAudioEngine {
            let engine: AVAudioEngine = .init()
            let session: AVAudioSession = .sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .videoChat,
                                    options: [
                                        .defaultToSpeaker,
                                        .allowBluetooth,
                                        .mixWithOthers])
            // try session.setPreferredSampleRate(.opus48khz)
            // try session.setPreferredInputNumberOfChannels(2)
            // try session.setPreferredOutputNumberOfChannels(2)
            if engine.inputNode.isVoiceProcessingEnabled != voiceProcessing {
                try engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)
                print("Set input processing: \(voiceProcessing)")
            }
            if engine.outputNode.isVoiceProcessingEnabled != voiceProcessing {
                try engine.outputNode.setVoiceProcessingEnabled(voiceProcessing)
                print("Set output processing: \(voiceProcessing)")
            }
            
            print("Input sample rate: \(engine.inputNode.outputFormat(forBus: 0).streamDescription.pointee)")
            print("Output sample rate: \(engine.outputNode.inputFormat(forBus: 0).streamDescription.pointee)")
            return engine
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

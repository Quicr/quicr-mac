import SwiftUI
import AVFoundation
import os

@MainActor
struct CallControls: View {
    @StateObject private var viewModel: ViewModel

    @Binding var leaving: Bool

    @State private var cameraModalExpanded: Bool = false
    @State private var muteModalExpanded: Bool = false

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(
        background: .black,
        foreground: .gray,
        hoverColour: .blue
    )

    init(captureManager: CaptureManager?, engine: DecimusAudioEngine, leaving: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: ViewModel(captureManager: captureManager, engine: engine))
        _leaving = leaving
    }

    private func openCameraModal() {
        cameraModalExpanded.toggle()
        muteModalExpanded = false
    }

    private func openAudioModal() {
        muteModalExpanded.toggle()
        cameraModalExpanded = false
    }

    var body: some View {
        HStack(alignment: .center) {
            ActionPicker(
                viewModel.audioOn ? "Mute" : viewModel.talkingWhileMuted ? "Talking while muted" : "Unmute",
                icon: viewModel.audioOn ?
                      "microphone-on" :
                      (viewModel.talkingWhileMuted ? "waveform.slash" : "microphone-muted"),
                role: viewModel.audioOn ? nil : .destructive,
                expanded: $muteModalExpanded,
                action:  { viewModel.toggleMicrophone() },
                pickerAction: { openAudioModal() }
            ) {
                Text("Audio Connection")
                    .foregroundColor(.gray)
                ForEach(viewModel.devices(.audio), id: \.uniqueID) { microphone in
                    ActionButton(
                        disabled: viewModel.isAlteringMicrophone(),
                        cornerRadius: 12,
                        styleConfig: deviceButtonStyleConfig,
                        action: { viewModel.toggleDevice(device: microphone) }) {
                            HStack {
                                Image(systemName: microphone.deviceType == .builtInMicrophone ?
                                      "mic" : "speaker.wave.2")
                                .renderingMode(.original)
                                .foregroundColor(.gray)
                                Text(microphone.localizedName).tag(microphone)
                            }
                        }
                        .aspectRatio(contentMode: .fill)
                }
            }
            .onChange(of: viewModel.selectedMicrophone) { _ in
                guard let microphone = viewModel.selectedMicrophone else { return }
                viewModel.toggleDevice(device: microphone)
            }
            .disabled(viewModel.isAlteringMicrophone())

            ActionPicker(
                viewModel.videoOn ? "Stop Video" : "Start Video",
                icon: viewModel.videoOn ? "video-on" : "video-off",
                role: viewModel.videoOn ? nil : .destructive,
                expanded: $cameraModalExpanded,
                action: { viewModel.toggleVideos() },
                pickerAction: { openCameraModal() }
            ) {
                LazyVGrid(columns: [GridItem(.fixed(16)), GridItem(.flexible())],
                          alignment: .leading) {
                    Image("video-on")
                        .renderingMode(.template)
                        .foregroundColor(.gray)
                    Text("Camera")
                        .padding(.leading)
                        .foregroundColor(.gray)
                    ForEach(viewModel.devices(.video), id: \.self) { camera in
                        if viewModel.alteringDevice[camera] ?? false {
                            ProgressView()
                        } else if viewModel.devices(.video).contains(camera) {
                            Image(systemName: "checkmark")
                        } else {
                            Spacer()
                        }
                        ActionButton(
                            disabled: viewModel.alteringDevice[camera] ?? false,
                            cornerRadius: 10,
                            styleConfig: deviceButtonStyleConfig,
                            action: { viewModel.toggleDevice(device: camera) },
                            title: {
                                Text(verbatim: camera.localizedName)
                                    .lineLimit(1)
                            }
                        )
                    }
                }
                .frame(maxWidth: 300, alignment: .bottomTrailing)
                .padding(.bottom)
            }
            .disabled(viewModel.devices(.video).allSatisfy { !(viewModel.alteringDevice[$0] ?? false) })

            Button(action: {
                leaving = true
                muteModalExpanded = false
                cameraModalExpanded = false
            }, label: {
                Image("cancel")
                    .renderingMode(.template)
                    .foregroundColor(.white)
                    .padding()
            })
            .foregroundColor(.white)
            .background(.red)
            .clipShape(Circle())
        }
        .frame(maxWidth: 650)
        .scaledToFit()
    }
}

extension CallControls {
    @MainActor
    class ViewModel: ObservableObject {
        private static let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier!,
            category: String(describing: CallControls.ViewModel.self)
        )

        @Published private(set) var alteringDevice: [AVCaptureDevice: Bool] = [:]
        @Published var selectedMicrophone: AVCaptureDevice?
        @Published var audioOn: Bool = true
        @Published var videoOn: Bool = true
        @Published var talkingWhileMuted: Bool = false
        private unowned let capture: CaptureManager?
        private unowned let engine: AVAudioEngine

        init(captureManager: CaptureManager?, engine: DecimusAudioEngine) {
            self.selectedMicrophone = AVCaptureDevice.default(for: .audio)
            self.capture = captureManager
            self.engine = engine.engine
            audioOn = !self.engine.inputNode.isVoiceProcessingInputMuted
#if compiler(>=5.9)
            if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, visionOS 1.0, *) {
                let success = self.engine.inputNode.setMutedSpeechActivityEventListener { [weak self] voiceEvent in
                    guard let self = self else { return }
                    switch voiceEvent {
                    case .started:
                        self.talkingWhileMuted = true
                        Self.logger.info("Talking while muted")
                    case .ended:
                        self.talkingWhileMuted = false
                        Self.logger.info("Stopped talking while muted")
                    default:
                        break
                    }
                }
                guard success else {
                    Self.logger.error("Unable to set muted speech activity listener")
                    return
                }
            }
#endif
        }

        deinit {
#if compiler(>=5.9)
            if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, visionOS 1.0, *) {
                let success = engine.inputNode.setMutedSpeechActivityEventListener(nil)
                guard success else {
                    Self.logger.warning("Unable to unset muted speech activity listener")
                    return
                }
            }
#endif
        }

        func toggleVideos() {
           for camera in devices(.video) {
               toggleDevice(device: camera)
           }
       }

        func devices(_ type: AVMediaType? = nil) -> [AVCaptureDevice] {
            do {
                var devices = try capture?.devices() ?? []
                if let type = type {
                    devices = devices.filter { $0.hasMediaType(type) }
                }
                return devices
            } catch {
                Self.logger.error("Failed to query devices: \(error.localizedDescription)")
                return []
            }
        }

        func activeDevices(_ type: AVMediaType? = nil) -> [AVCaptureDevice] {
            do {
                var devices = try capture?.activeDevices() ?? []
                if let type = type {
                    devices = devices.filter { $0.hasMediaType(type) }
                }
                return devices
            } catch {
                Self.logger.error("Failed to query active devices: \(error.localizedDescription)")
                return []
            }
        }

        func toggleMicrophone() {
            engine.inputNode.isVoiceProcessingInputMuted.toggle()
            self.audioOn = !engine.inputNode.isVoiceProcessingInputMuted
        }

        func toggleDevice(device: AVCaptureDevice) {
            guard !(alteringDevice[device] ?? false) else {
                return
            }
            guard let capture = capture else { return }
            alteringDevice[device] = true
            do {
                try capture.toggleInput(device: device) { [weak self] enabled in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.alteringDevice[device] = false
                        self.videoOn = enabled
                    }
                }
            } catch {
                Self.logger.error("Failed to toggle device: \(error.localizedDescription)")
            }
        }

        func isAlteringMicrophone() -> Bool {
            guard selectedMicrophone != nil else { return false }
            return alteringDevice[selectedMicrophone!] ?? false
        }
    }
}

struct CallControls_Previews: PreviewProvider {
    static var previews: some View {
        let bool: Binding<Bool> = .init(get: { return false }, set: { _ in })
        let capture: CaptureManager? = try? .init(metricsSubmitter: MockSubmitter(), granularMetrics: false)
        CallControls(captureManager: capture, engine: try! .init(), leaving: bool)
    }
}

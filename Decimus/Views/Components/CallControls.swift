import SwiftUI
import AVFoundation

@MainActor
struct CallControls: View {
    @EnvironmentObject private var errorHandler: ObservableError
    @StateObject var viewModel: ViewModel

    @Binding var leaving: Bool

    @State private var audioOn: Bool = true
    @State private var videoOn: Bool = true

    @State private var cameraModalExpanded: Bool = false
    @State private var muteModalExpanded: Bool = false

    private var cameras: [AVCaptureDevice] {
        viewModel.devices(.video)
    }

    private var audioDevices: [AVCaptureDevice] {
        viewModel.devices(.audio)
    }

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(
        background: .black,
        foreground: .gray,
        hoverColour: .blue
    )

    init(errorWriter: ErrorWriter, captureManager: CaptureManager?, leaving: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: ViewModel(errorWriter: errorWriter, captureManager: captureManager))
        _leaving = leaving
    }

    private func toggleVideo(device: AVCaptureDevice) {
        videoOn = false
        viewModel.toggleDevice(device: device) {
            videoOn = videoOn || $0
        }
    }

    private func toggleAudio(device: AVCaptureDevice) {
        audioOn = false
        viewModel.toggleDevice(device: device) {
            audioOn = audioOn || $0
        }
    }

    private func toggleVideos() {
        for camera in viewModel.devices(.video) {
            toggleVideo(device: camera)
        }
    }

    private func toggleAudios() {
        // TODO: Mute status needs to come from elsewhere.
        for microphone in viewModel.devices(.audio) {
            toggleAudio(device: microphone)
        }
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
                audioOn ? "Mute" : "Unmute",
                icon: audioOn ? "microphone-on" : "microphone-muted",
                role: audioOn ? nil : .destructive,
                expanded: $muteModalExpanded,
                action: toggleAudios,
                pickerAction: openAudioModal
            ) {
                Text("Audio Connection")
                    .foregroundColor(.gray)
                ForEach(audioDevices, id: \.uniqueID) { microphone in
                    ActionButton(
                        disabled: viewModel.isAlteringMicrophone(),
                        cornerRadius: 12,
                        styleConfig: deviceButtonStyleConfig,
                        action: { toggleAudio(device: microphone) }) {
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
                toggleAudio(device: microphone)
            }
            .disabled(viewModel.isAlteringMicrophone())

            ActionPicker(
                videoOn ? "Stop Video" : "Start Video",
                icon: videoOn ? "video-on" : "video-off",
                role: videoOn ? nil : .destructive,
                expanded: $cameraModalExpanded,
                action: toggleVideos,
                pickerAction: openCameraModal
            ) {
                LazyVGrid(columns: [GridItem(.fixed(16)), GridItem(.flexible())],
                          alignment: .leading) {
                    Image("video-on")
                        .renderingMode(.template)
                        .foregroundColor(.gray)
                    Text("Camera")
                        .padding(.leading)
                        .foregroundColor(.gray)
                    ForEach(cameras, id: \.self) { camera in
                        if viewModel.alteringDevice[camera] ?? false {
                            ProgressView()
                        } else if cameras.contains(camera) {
                            Image(systemName: "checkmark")
                        } else {
                            Spacer()
                        }
                        ActionButton(
                            disabled: viewModel.alteringDevice[camera] ?? false,
                            cornerRadius: 10,
                            styleConfig: deviceButtonStyleConfig,
                            action: { toggleVideo(device: camera) },
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
            .disabled(cameras.allSatisfy { !(viewModel.alteringDevice[$0] ?? false) })

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
        .onDisappear(perform: { viewModel.leave() })
    }
}

extension CallControls {
    @MainActor
    class ViewModel: ObservableObject {
        @Published private(set) var alteringDevice: [AVCaptureDevice: Bool] = [:]
        @Published var selectedMicrophone: AVCaptureDevice?
        private unowned let capture: CaptureManager?
        private let errorWriter: ErrorWriter

        init(errorWriter: ErrorWriter, captureManager: CaptureManager?) {
            self.errorWriter = errorWriter
            self.selectedMicrophone = AVCaptureDevice.default(for: .audio)
            self.capture = captureManager
        }

        func leave() {
            alteringDevice.removeAll()
        }

        func devices(_ type: AVMediaType? = nil) -> [AVCaptureDevice] {
            do {
                var devices = try capture?.devices() ?? []
                if let type = type {
                    devices = devices.filter { $0.hasMediaType(type) }
                }
                return devices
            } catch {
                errorWriter.writeError("Failed to query devices: \(error.localizedDescription)")
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
                errorWriter.writeError("Failed to query active devices: \(error.localizedDescription)")
                return []
            }
        }

        func toggleDevice(device: AVCaptureDevice, callback: @escaping (Bool) -> Void) {
            guard !(alteringDevice[device] ?? false) else {
                return
            }
            guard let capture = capture else { return }
            alteringDevice[device] = true
            do {
                try capture.toggleInput(device: device) { [weak self] enabled in
                    DispatchQueue.main.async {
                        self?.alteringDevice[device] = false
                        callback(enabled)
                    }
                }
            } catch {
                errorWriter.writeError("Failed to toggle device: \(error.localizedDescription)")
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
        let errorWriter: ObservableError = .init()
        let capture: CaptureManager? = try? .init()
        CallControls(errorWriter: errorWriter, captureManager: capture, leaving: bool)
    }
}

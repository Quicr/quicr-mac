import SwiftUI
import AVFoundation

struct CallControls: View {
    @StateObject var viewModel: ViewModel

    @Binding var leaving: Bool

    @State private var audioOn: Bool = true
    @State private var videoOn: Bool = true
    @State private var cameraModalExpanded: Bool = false
    @State private var muteModalExpanded: Bool = false

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(
        background: .black,
        foreground: .gray,
        hoverColour: .blue
    )

    init(errorWriter: ErrorWriter, leaving: Binding<Bool>) {
        _viewModel = StateObject(wrappedValue: ViewModel(errorWriter: errorWriter))
        _leaving = leaving
    }

    private func toggleVideo() async {
        var anyVideo = false
        for (camera, _) in viewModel.usingDevice where camera.hasMediaType(.video) {
            let enabled = await viewModel.toggleDevice(device: camera)
            anyVideo = anyVideo || enabled
        }
        videoOn = anyVideo
    }

    private func toggleAudio() async {
        var anyAudio = false
        for (microphone, _) in viewModel.usingDevice where microphone.hasMediaType(.audio) {
            let enabled = await viewModel.toggleDevice(device: microphone)
            anyAudio = anyAudio || enabled
        }
        audioOn = anyAudio
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
                action: toggleAudio,
                pickerAction: openAudioModal
            ) {
                Text("Audio Connection")
                    .foregroundColor(.gray)
                ForEach(viewModel.devices.audioInputs, id: \.uniqueID) { microphone in
                    ActionButton(
                        disabled: viewModel.isAlteringMicrophone(),
                        cornerRadius: 12,
                        styleConfig: deviceButtonStyleConfig,
                        action: toggleAudio) {
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
                guard viewModel.selectedMicrophone != nil else { return }
                Task { await viewModel.toggleDevice(device: viewModel.selectedMicrophone!) }
            }
            .disabled(viewModel.isAlteringMicrophone())

            ActionPicker(
                videoOn ? "Stop Video" : "Start Video",
                icon: videoOn ? "video-on" : "video-off",
                role: videoOn ? nil : .destructive,
                expanded: $cameraModalExpanded,
                action: toggleVideo,
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
                    ForEach(viewModel.devices.cameras, id: \.self) { camera in
                        if viewModel.alteringDevice[camera] ?? false {
                            ProgressView()
                        } else if viewModel.usingDevice[camera] ?? false {
                            Image(systemName: "checkmark")
                        } else {
                            Spacer()
                        }
                        ActionButton(
                            disabled: viewModel.alteringDevice[camera] ?? false,
                            cornerRadius: 10,
                            styleConfig: deviceButtonStyleConfig,
                            action: { _ = await viewModel.toggleDevice(device: camera) },
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
            .disabled(viewModel.devices.cameras.allSatisfy({ !(viewModel.alteringDevice[$0] ?? false) }))

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
        .scaledToFit()
    }
}

extension CallControls {
    @MainActor
    class ViewModel: ObservableObject {
        @Published private(set) var devices = AudioVideoDevices()
        @Published private(set) var alteringDevice: [AVCaptureDevice: Bool] = [:]
        @Published private(set) var usingDevice: [AVCaptureDevice: Bool] = [:]
        @Published var selectedMicrophone: AVCaptureDevice?
        @Published var capture: CaptureManager

        private var notifier: NotificationCenter = .default

        init(errorWriter: ErrorWriter) {
            self.capture = .init(errorHandler: errorWriter)
            self.selectedMicrophone = AVCaptureDevice.default(for: .audio)
            self.notifier.addObserver(self,
                                      selector: #selector(join),
                                      name: .connected,
                                      object: nil)
            self.notifier.addObserver(self,
                                      selector: #selector(leave),
                                      name: .disconnected,
                                      object: nil)
            self.notifier.addObserver(self,
                                      selector: #selector(addInputDevice),
                                      name: .publicationPreparedForDevice,
                                      object: nil)
        }

        @objc private func join(_ notification: Notification) {
            Task { await capture.startCapturing() }
        }

        @objc private func leave(_ notification: Notification) {
            usingDevice.forEach({ device, _ in
                Task { await capture.removeInput(device: device) }
            })
            usingDevice.removeAll()
            alteringDevice.removeAll()

            Task { await capture.stopCapturing() }
        }

        @objc private func addInputDevice(_ notification: Notification) {
            guard let publication = notification.object as? Publication else {
                let object = notification.object as Any
                assertionFailure("Invalid device: \(object)")
                return
            }

            Task { await addDevice(device: publication.device!,
                                   delegateCapture: publication.capture,
                                   queue: publication.queue) }
        }

        func addDevice(device: AVCaptureDevice,
                       delegateCapture: PublicationCaptureDelegate?,
                       queue: DispatchQueue) async {
            guard !(alteringDevice[device] ?? false) else {
                return
            }
            alteringDevice[device] = true
            await capture.addInput(device: device, delegateCapture: delegateCapture, queue: queue)
            usingDevice[device] = true
            alteringDevice[device] = false
        }

        func toggleDevice(device: AVCaptureDevice) async -> Bool {
            guard !(alteringDevice[device] ?? false) else {
                print("??")
                return false
            }
            alteringDevice[device] = true
            let enabled = await capture.toggleInput(device: device)
            usingDevice[device] = enabled
            alteringDevice[device] = false
            return enabled
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
        CallControls(errorWriter: ObservableError(), leaving: bool)
    }
}

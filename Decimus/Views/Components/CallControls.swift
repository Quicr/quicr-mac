import SwiftUI
import AVFoundation

struct CallControls: View {
    @EnvironmentObject var controller: CallController

    @Binding var leaving: Bool

    @State private var audioOn: Bool = true
    @State private var videoOn: Bool = true
    @State private var cameraModalExpanded: Bool = true
    @State private var muteModalExpanded: Bool = false

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(
        background: .black,
        foreground: .gray,
        hoverColour: .blue
    )

    init(leaving: Binding<Bool>) {
        _leaving = leaving
    }

    private func toggleVideo() async {
        if controller.devices.cameras.allSatisfy({ camera in
            return !(controller.usingDevice[camera] ?? false)
        }) {
            guard let camera = AVCaptureDevice.default(for: .video) else { return }
            await controller.addDevice(device: camera)
            videoOn = true
            return
        }

        videoOn = false
        controller.devices.cameras.forEach { camera in
            guard controller.usingDevice[camera] ?? false else { return }
            Task { await controller.removeDevice(device: camera) }
        }
    }

    private func openCameraModal() {
        cameraModalExpanded.toggle()
        muteModalExpanded = false
    }

    private func toggleMute() async {
        audioOn = await controller.toggleMute()
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
                action: toggleMute,
                pickerAction: openAudioModal
            ) {
                Text("Audio Connection")
                    .foregroundColor(.gray)
                ForEach(controller.devices.audioInputs, id: \.uniqueID) { microphone in
                    ActionButton(
                        disabled: controller.isAlteringMicrophone(),
                        cornerRadius: 12,
                        styleConfig: deviceButtonStyleConfig,
                        action: toggleMute) {
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
            .onChange(of: controller.selectedMicrophone) { _ in
                guard controller.selectedMicrophone != nil else { return }
                Task { await controller.toggleCamera(device: controller.selectedMicrophone!) }
            }
            .disabled(controller.isAlteringMicrophone())

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
                    ForEach(controller.devices.cameras, id: \.self) { camera in
                        if controller.alteringDevice[camera] ?? false {
                            ProgressView()
                        } else if controller.usingDevice[camera] ?? false {
                            Image(systemName: "checkmark")
                        } else {
                            Spacer()
                        }
                        ActionButton(
                            disabled: controller.alteringDevice[camera] ?? false,
                            cornerRadius: 10,
                            styleConfig: deviceButtonStyleConfig,
                            action: { await controller.toggleCamera(device: camera) },
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
            .disabled(controller.devices.cameras.allSatisfy({ !(controller.alteringDevice[$0] ?? false) }))

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

@MainActor
class CallController: ObservableObject {
    @Published private(set) var devices = AudioVideoDevices()
    @Published private(set) var alteringDevice: [AVCaptureDevice: Bool] = [:]
    @Published private(set) var usingDevice: [AVCaptureDevice: Bool] = [:]
    @Published var selectedMicrophone: AVCaptureDevice?
    @Published var capture: CaptureManager?

    init(mode: ApplicationModeBase, errorHandler: ErrorWriter) {
        self.selectedMicrophone = AVCaptureDevice.default(for: .audio)
        self.capture = .init(
            cameraCallback: mode.encodeCameraFrame,
            audioCallback: mode.encodeAudioSample,
            deviceChangeCallback: mode.onDeviceChange,
            errorHandler: errorHandler
        )
    }

    func join() async {
        if let defaultCamera = AVCaptureDevice.default(for: .video) {
            await addDevice(device: defaultCamera)
        }
        if selectedMicrophone != nil {
            await addDevice(device: selectedMicrophone!)
        }

        await capture!.startCapturing()
    }

    func leave() async {
        usingDevice.forEach({ device, _ in
            Task { await capture!.removeInput(device: device) }
        })
        usingDevice.removeAll()
        alteringDevice.removeAll()

        await capture!.stopCapturing()
    }

    func addDevice(device: AVCaptureDevice) async {
        guard !(alteringDevice[device] ?? false) else {
            return
        }
        alteringDevice[device] = true
        await capture!.addInput(device: device)
        usingDevice[device] = true
        alteringDevice[device] = false
    }

    func removeDevice(device: AVCaptureDevice) async {
        guard !(alteringDevice[device] ?? false) else {
            return
        }
        alteringDevice[device] = true
        await capture!.removeInput(device: device)
        usingDevice[device] = false
        alteringDevice[device] = false
    }

    func toggleCamera(device: AVCaptureDevice) async {
        guard !(alteringDevice[device] ?? false) else {
            return
        }
        alteringDevice[device] = true
        usingDevice[device] = await capture!.toggleInput(device: device)
        alteringDevice[device] = false
    }

    func isAlteringMicrophone() -> Bool {
        guard selectedMicrophone != nil else { return false }
        return alteringDevice[selectedMicrophone!] ?? false
    }

    func isUsingMicrophone() async -> Bool {
        return await capture!.isMuted()
    }

    func toggleMute() async -> Bool {
        guard selectedMicrophone != nil else { return false }
        return await capture!.toggleAudio()
    }
}

struct CallControls_Previews: PreviewProvider {
    static var previews: some View {
        let bool: Binding<Bool> = .init(get: { return false }, set: { _ in })
        let errorWriter: ObservableError = .init()
        let controller: CallController = .init(mode: RawLoopback(errorWriter: errorWriter), errorHandler: errorWriter)
        CallControls(leaving: bool).environmentObject(controller)
    }
}

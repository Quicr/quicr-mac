import SwiftUI
import AVFoundation

struct CallControls: View {
    @State var controller: CallController

    @State private var cameraButtonText: String
    @State private var cameraIconName: String
    @State private var cameraModalExpanded: Bool = false

    @State private var micButtonText: String
    @State private var micIconName: String
    @State private var muteModalExpanded: Bool = false

    @Binding private var leaving: Bool

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(background: .black,
                                                                  foreground: .gray,
                                                                  hoverColour: .blue)

    init(controller: CallController, leaving: Binding<Bool>) {
        self.controller = controller
        _leaving = leaving

        cameraButtonText = "Stop Video"
        cameraIconName = "video"
        micButtonText = "Mute"
        micIconName = "mic"
    }

    private func toggleVideo() {
        if controller.devices.cameras.allSatisfy({ camera in
            return !controller.isUsingCamera(device: camera)
        }) {
            guard let camera = AVCaptureDevice.default(for: .video) else { return }
            Task { await controller.addDevice(device: camera) }
            cameraButtonText = "Stop Video"
            cameraIconName = "video"
            return
        }

        controller.devices.cameras.forEach { camera in
            guard controller.isUsingCamera(device: camera) else { return }
            Task { await controller.removeDevice(device: camera) }
        }
        cameraButtonText =  "Start Video"
        cameraIconName = "video.slash"
    }

    private func toggleMute() async {
        await controller.toggleMute()
        if await controller.isUsingMicrophone() {
            micButtonText = "Mute"
            micIconName = "mic"
        } else {
            micButtonText = "Unmute"
            micIconName = "mic.slash"
        }
    }

    var body: some View {
        HStack(alignment: .center) {
            ActionPicker(micButtonText,
                         icon: micIconName,
                         expanded: $muteModalExpanded,
                         action: toggleMute,
                         pickerAction: {
                muteModalExpanded.toggle()
                cameraModalExpanded = false
            },
                         content: {
                HStack {
                    Text("Audio Connection")
                        .foregroundColor(.gray)
                }
                .aspectRatio(contentMode: .fill)
                .padding([.horizontal, .top])
                ForEach(controller.devices.audioInputs, id: \.uniqueID) { microphone in
                    ActionButton(
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
            })
            .onChange(of: controller.selectedMicrophone) { _ in
                guard controller.selectedMicrophone != nil else { return }
                Task { await controller.toggleCamera(device: controller.selectedMicrophone!) }
            }
            .disabled(controller.isAlteringMicrophone())
            .padding(.horizontal)
            .frame(maxWidth: 210)

            ActionPicker(cameraButtonText,
                         icon: cameraIconName,
                         expanded: $cameraModalExpanded,
                         action: toggleVideo,
                         pickerAction: {
                cameraModalExpanded.toggle()
                muteModalExpanded = false
            },
                         content: {
                HStack {
                    Image(systemName: "video")
                        .renderingMode(.original)
                        .foregroundColor(.gray)
                    Text("Camera")
                        .foregroundColor(.gray)
                }
                .padding([.horizontal, .top])
                ForEach(controller.devices.cameras, id: \.self) { camera in
                    ActionButton(
                        cornerRadius: 10,
                        styleConfig: deviceButtonStyleConfig,
                        action: {
                            await controller.toggleCamera(device: camera)
                        },
                        title: {
                            HStack {
                                ZStack {
                                    if controller.alteringDevice[camera] ?? false {
                                        ProgressView()
                                        Spacer()
                                    } else if controller.usingDevice[camera] ?? false {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .frame(maxWidth: 20)
                                Text(verbatim: camera.localizedName)
                                Spacer()
                            }
                        }
                    )
                    .disabled(controller.isAlteringDevice(device: camera))
                    .aspectRatio(contentMode: .fill)
                }
                .disabled(controller.devices.cameras.first(where: { camera in
                    return controller.isAlteringDevice(device: camera)
                }) != nil)
                .frame(maxWidth: 300, alignment: .bottomTrailing)
                .padding(.bottom)
            })
            .padding(.horizontal)
            .frame(maxWidth: 250)

            Button(action: {
                leaving = true
                muteModalExpanded = false
                cameraModalExpanded = false
            }, label: {
                Image(systemName: "xmark")
                    .padding()
                    .background(.red)
            })
            .padding(.horizontal)
            .foregroundColor(.white)
            .clipShape(Circle())
        }
    }
}

class CallController: ObservableObject {
    @Published private(set) var devices = AudioVideoDevices()
    @Published private(set) var alteringDevice: [AVCaptureDevice: Bool] = [:]
    @Published private(set) var usingDevice: [AVCaptureDevice: Bool] = [:]
    @Published var selectedMicrophone: AVCaptureDevice?
    @Published var capture: CaptureManager?

    init(mode: ApplicationModeBase, errorHandler: ErrorWriter) {
        self.selectedMicrophone = AVCaptureDevice.default(for: .audio)!
        self.capture = .init(
            cameraCallback: mode.encodeCameraFrame,
            audioCallback: mode.encodeAudioSample,
            deviceChangeCallback: mode.onDeviceChange,
            errorHandler: errorHandler
        )
    }

    deinit {
        self.capture = nil
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
        alteringDevice[device] = true
        await capture!.addInput(device: device)
        usingDevice[device] = true
        alteringDevice[device] = false
    }

    func removeDevice(device: AVCaptureDevice) async {
        alteringDevice[device] = true
        await capture!.removeInput(device: device)
        usingDevice[device] = false
        alteringDevice[device] = false
    }

    func toggleCamera(device: AVCaptureDevice) async {
        alteringDevice[device] = true
        usingDevice[device] = await capture!.toggleInput(device: device)
        alteringDevice[device] = false
    }

    func isAlteringDevice(device: AVCaptureDevice) -> Bool {
        return alteringDevice[device] ?? false
    }

    func isUsingCamera(device: AVCaptureDevice) -> Bool {
        return usingDevice[device] ?? false
    }

    func isAlteringMicrophone() -> Bool {
        guard selectedMicrophone != nil else { return false }
        return alteringDevice[selectedMicrophone!] ?? false
    }

    func isUsingMicrophone() async -> Bool {
        return await capture!.isMuted()
    }

    func toggleMute() async {
        guard selectedMicrophone != nil else { return }
        await capture!.toggleAudio()
    }
}

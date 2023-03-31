import SwiftUI
import AVFoundation
import UIKit

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView<Mode>: View where Mode: ApplicationModeBase {
    @StateObject var viewModel = ViewModel()

    @State private var cameraButtonText: String
    @State private var cameraIconName: String
    @State private var micButtonText: String
    @State private var micIconName: String

    @State private var muteModalExpanded: Bool = false
    @State private var cameraModalExpanded: Bool = false
    @State private var leaving: Bool = false

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(background: .black,
                                                                  foreground: .gray,
                                                                  hoverColour: .blue)

    /// Callback when call is left.
    private let onLeave: () -> Void
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    init(onLeave: @escaping () -> Void) {
        self.onLeave = onLeave

        cameraButtonText = "Stop Video"
        cameraIconName = "video"
        micButtonText = "Mute"
        micIconName = "mic"
    }

    init() {
        self.init(onLeave: {})
    }

    var body: some View {
        ZStack {
            VStack {
                VideoGrid(participants: viewModel.mode!.participants)
                    .scaledToFit()
                    .frame(maxWidth: .infinity)

                // Controls.
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
                        ForEach(viewModel.devices.audioInputs, id: \.uniqueID) { microphone in
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
                    .onChange(of: viewModel.selectedMicrophone) { _ in
                        Task { await viewModel.toggleDevice(device: viewModel.selectedMicrophone) }
                    }
                    .disabled(viewModel.isAlteringMicrophone())
                    .padding(.horizontal)
                    .frame(maxWidth: 200)

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
                        ForEach(viewModel.devices.cameras, id: \.self) { camera in
                            ActionButton(
                                cornerRadius: 10,
                                styleConfig: deviceButtonStyleConfig,
                                action: { await viewModel.toggleDevice(device: camera) },
                                title: {
                                    HStack {
                                        ZStack {
                                            if viewModel.alteringDevice[camera] ?? false {
                                                ProgressView()
                                                Spacer()
                                            } else if viewModel.usingDevice[camera] ?? false {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                        .frame(width: 20)
                                        Text(verbatim: camera.localizedName)
                                        Spacer()
                                    }
                                    .padding(.vertical, -10)
                                }
                            )
                            .disabled(viewModel.alteringDevice[camera] ?? false)
                            .aspectRatio(contentMode: .fill)
                        }
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
                .padding(.bottom, 30)
            }
            .edgesIgnoringSafeArea(.top) // Note: Only because of navigation bar forcing whole content down by 50

            if leaving {
                LeaveModal(leaveAction: {
                                onLeave()
                            },
                           cancelAction: { leaving = false }
                )
                .frame(maxWidth: 500, maxHeight: 75, alignment: .center)
            }

            // Error messages.
            VStack {
                if !viewModel.errorHandler.messages.isEmpty {
                    Text("Errors:")
                        .font(.title)
                        .foregroundColor(.red)

                    // Clear all.
                    Button {
                        viewModel.errorHandler.messages.removeAll()
                    } label: {
                        Text("Clear Errors")
                    }
                    .buttonStyle(.borderedProminent)

                    // Show the messages.
                    ScrollView {
                        ForEach(viewModel.errorHandler.messages) { message in
                            Text(message.message)
                                .padding()
                                .background(Color.red)
                        }
                    }
                }
            }
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
    }

    private func toggleVideo() async {
//        if viewModel.usingDevice[camera]! {
//            cameraButtonText = "Stop Video"
//            cameraIconName = "video"
//        } else {
//            cameraButtonText =  "Start Video"
//            cameraIconName = "video.slash"
//        }
    }

    private func toggleMute() async {
        await viewModel.toggleDevice(device: viewModel.selectedMicrophone)
        if viewModel.usingDevice[viewModel.selectedMicrophone]! {
            micButtonText = "Mute"
            micIconName = "mic"
        } else {
            micButtonText = "Unmute"
            micIconName = "mic.slash"
        }
    }
}

extension InCallView {
    @MainActor
    class ViewModel: ObservableObject {
        @Published private(set) var devices = AudioVideoDevices()
        @Published private(set) var errorHandler = ObservableError()
        @Published private(set) var alteringDevice: [AVCaptureDevice: Bool] = [:]
        @Published private(set) var usingDevice: [AVCaptureDevice: Bool] = [:]
        @Published private(set) var selectedMicrophone: AVCaptureDevice

        private(set) var mode: Mode?
        private var capture: CaptureManager?

        init() {
            self.selectedMicrophone = AVCaptureDevice.default(for: .audio)!
            self.mode = .init(errorWriter: errorHandler)
            self.capture = .init(
                cameraCallback: mode!.encodeCameraFrame,
                audioCallback: mode!.encodeAudioSample,
                deviceChangeCallback: mode!.onDeviceChange,
                errorHandler: errorHandler
            )
        }

        func join() async {
            if let defaultCamera = AVCaptureDevice.default(for: .video) {
                await addDevice(device: defaultCamera)
            }
            await addDevice(device: selectedMicrophone)
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

        func toggleDevice(device: AVCaptureDevice) async {
            alteringDevice[device] = true
            usingDevice[device] = await capture!.toggleInput(device: device)
            alteringDevice[device] = false
        }

        func isAlteringMicrophone() -> Bool {
            return alteringDevice[selectedMicrophone] ?? false
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

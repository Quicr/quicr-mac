import SwiftUI
import AVFoundation
import UIKit

private struct LeaveModal: View {
    private let leaveAction: () -> Void
    private let cancelAction: () -> Void

    init(leaveAction: @escaping () -> Void, cancelAction: @escaping () -> Void) {
        self.leaveAction = leaveAction
        self.cancelAction = cancelAction
    }

    init(leaveAction: @escaping () async -> Void, cancelAction: @escaping () async -> Void) {
        self.leaveAction = { Task { await leaveAction() }}
        self.cancelAction = { Task { await cancelAction() }}
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.gray, lineWidth: 1)
                .background(.black)
            VStack(alignment: .leading) {
                Text("Leave Meeting")
                    .foregroundColor(.white)
                    .font(.title)
                    .padding(.bottom)
                Text("Do you want to leave this meeting?")
                    .foregroundColor(.gray)
                    .font(.body)
                    .padding(.bottom)
                HStack {
                    Spacer().frame(maxWidth: .infinity)
                    ActionButton("Cancel",
                                 styleConfig: ActionButtonStyleConfig(
                                    background: .black,
                                    foreground: .white,
                                    borderColour: .gray),
                                 action: cancelAction)
                    ActionButton("Leave Meeting",
                                 styleConfig: ActionButtonStyleConfig(
                                    background: .white,
                                    foreground: .black),
                                 action: leaveAction)
                }
                .frame(alignment: .trailing)
            }
            .padding()
        }
        .cornerRadius(12)
    }
}

/// View for display grid of videos
private struct VideoGrid: View {
    private let videos: [VideoParticipant]
    private let maxColumns: Int = 4
    private let spacing: CGFloat = 10

    init(videos: [VideoParticipant]) {
        self.videos = videos
    }

    private func calcColumns() -> CGFloat {
        return .init(min(maxColumns, max(1, Int(ceil(sqrt(Double(videos.count)))))))
    }

    private func calcRows(_ columns: CGFloat) -> CGFloat {
        return .init(round(Float(videos.count) / Float(columns)))
    }

    var body: some View {
        GeometryReader { geo in
            let numColumns = calcColumns()
            let numRows = calcRows(numColumns)

            let width = (geo.size.width) / numColumns
            let height = abs(geo.size.height) / numRows
            let columns = Array(repeating: GridItem(.adaptive(minimum: width, maximum: width)),
                                count: Int(numColumns))

            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(videos) { participant in
                    participant.decodedImage
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                        .frame(maxHeight: height)
                }
            }
            .cornerRadius(12)
            .frame(height: geo.size.height)
        }
        .padding([.horizontal, .top])
    }
}

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {

    /// Available input devices.
    @EnvironmentObject var devices: AudioVideoDevices
    /// Local capture manager.
    @EnvironmentObject var capture: ObservableCaptureManager
    /// Images to render.
    @EnvironmentObject var render: VideoParticipants
    /// Error messages.
    @EnvironmentObject var errors: ObservableError

    // TODO: Is this still needed.
    /// Currently selected camera.
    @State private var selectedCamera: AVCaptureDevice
    /// Currently selected input microphone.
    @State private var selectedMicrophone: AVCaptureDevice
    /// Current altering status.
    @State private var alteringDevice: [AVCaptureDevice: Bool] = [:]
    /// Current usage.
    @State private var usingDevice: [AVCaptureDevice: Bool] = [:]
    /// Current device orientation.
    @State private var currentOrientation: AVCaptureVideoOrientation

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
    private var onLeave: () -> Void
    private let mode: ApplicationModeBase?
    private let orientationChanged = NotificationCenter
        .default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    /// Create a new in call view.
    /// - Parameter onLeave: Callback fired when user asks to leave the call.
    init(mode: ApplicationModeBase?, onLeave: @escaping () -> Void) {
        self.onLeave = onLeave
        self.mode = mode
        selectedCamera = AVCaptureDevice.default(for: .video)!
        selectedMicrophone = AVCaptureDevice.default(for: .audio)!
        currentOrientation = UIDevice.current.orientation.videoOrientation

        cameraButtonText = "Stop Video"
        cameraIconName = "video"
        micButtonText = "Mute"
        micIconName = "mic"
    }

    // Show a video player.
    var body: some View {
        ZStack {
            VStack {
                ZStack {
                    VideoGrid(videos: Array(render.participants.values))
                        .scaledToFit()
                        .frame(maxWidth: .infinity)

                    if leaving {
                        LeaveModal(leaveAction: leaveCall, cancelAction: { leaving = false })
                            .frame(maxWidth: 500, maxHeight: 75, alignment: .center)
                    }
                }

                // Controls.
                HStack(alignment: .center) {
                    ActionPicker(micButtonText,
                                 icon: micIconName,
                                 input: $selectedMicrophone,
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
                        ForEach(devices.audioInputs, id: \.uniqueID) { microphone in
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
                    .onChange(of: selectedMicrophone) { _ in
                        Task { await toggleMute() }
                    }
                    .disabled(alteringDevice[selectedMicrophone] ?? false)
                    .padding(.horizontal)
                    .frame(maxWidth: 200)

                    ActionPicker(cameraButtonText,
                                 icon: cameraIconName,
                                 input: $selectedCamera,
                                 expanded: $cameraModalExpanded,
                                 action: {
                                    // TODO: Should we disable everything here?
                                 },
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
                        ForEach(devices.cameras, id: \.self) { camera in
                            ActionButton(
                                cornerRadius: 10,
                                styleConfig: deviceButtonStyleConfig,
                                action: { await toggleVideo(camera: camera)}) {
                                    HStack {
                                        ZStack {
                                            if alteringDevice[camera] ?? false {
                                                ProgressView()
                                                Spacer()
                                            } else if usingDevice[camera] ?? false {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                        .frame(width: 20)
                                        Text(verbatim: camera.localizedName)
                                        Spacer()
                                    }
                                    .padding(.vertical, -10)
                                }
                                .disabled(alteringDevice[camera] ?? false)
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

                // Local video preview.
                // PreviewView(device: $selectedCamera)
            }
            .edgesIgnoringSafeArea(.top) // Note: Only because of navigation bar forcing whole content down by 50

            // Error messages.
            VStack {
                if !errors.messages.isEmpty {
                    Text("Errors:")
                        .font(.title)
                        .foregroundColor(.red)

                    // Clear all.
                    Button {
                        errors.messages.removeAll()
                    } label: {
                        Text("Clear Errors")
                    }
                    .buttonStyle(.borderedProminent)

                    // Show the messages.
                    ScrollView {
                        ForEach(errors.messages) { message in
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
            await joinCall()
        }
        .onDisappear {
            Task {
                await leaveCall()
            }
        }
        .onReceive(orientationChanged) { _ in
            self.currentOrientation = UIDevice.current.orientation.videoOrientation
            Task {
                await self.capture.manager!.setOrientation(orientation: self.currentOrientation)
            }
        }
    }

    private func joinCall() async {
        // Bind pipeline to capture manager.
        capture.videoCallback = mode!.encodeCameraFrame
        capture.audioCallback = mode!.encodeAudioSample
        capture.deviceChangeCallback = mode!.onDeviceChange

        // Use default devices.
        await capture.manager!.addInput(device: selectedMicrophone)
        let defaultCamera = AVCaptureDevice.default(for: .video)!
        alteringDevice[defaultCamera] = true
        await capture.manager!.addInput(device: defaultCamera)
        usingDevice[defaultCamera] = true
        alteringDevice[defaultCamera] = false

        await capture.manager!.startCapturing()
    }

    private func leaveCall() async {
        // Stop capturing.
        await capture.manager!.stopCapturing()

        // Remove devices.
        await capture.manager!.removeInput(device: selectedMicrophone)

        // Unbind pipeline.
        capture.videoCallback = nil
        capture.audioCallback = nil
        capture.deviceChangeCallback = nil

        // Report left.
        onLeave()
    }

    private func toggleVideo(camera: AVCaptureDevice) async {
        alteringDevice[camera] = true
        usingDevice[camera] = await capture.manager!.toggleInput(device: camera)
        if usingDevice[camera]! {
            cameraButtonText = "Stop Video"
            cameraIconName = "video"
        } else {
            cameraButtonText =  "Start Video"
            cameraIconName = "video.slash"
        }
        alteringDevice[camera] = false
    }

    private func toggleMute() async {
        alteringDevice[selectedMicrophone] = true
        usingDevice[selectedMicrophone] = await capture.manager!.toggleInput(device: selectedMicrophone)
        if usingDevice[selectedMicrophone]! {
            micButtonText = "Mute"
            micIconName = "mic"
        } else {
            micButtonText = "Unmute"
            micIconName = "mic.slash"
        }
        alteringDevice[selectedMicrophone] = false
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(mode: nil) {}
    }
}

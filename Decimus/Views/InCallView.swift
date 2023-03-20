import SwiftUI
import AVFoundation
import UIKit

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
        return .init(ceil(Float(videos.count) / Float(columns)))
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
                    Image(uiImage: participant.decodedImage)
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
            VStack(alignment: .center) {
                VideoGrid(videos: Array(render.participants.values))
                    .scaledToFit()
                    .frame(maxWidth: .infinity)

                // Controls.
                HStack(alignment: .center) {
                    ActionPicker(micButtonText,
                                 icon: micIconName,
                                 input: $selectedMicrophone,
                                 action: toggleMute,
                                 content: {
                        ForEach(devices.audioInputs, id: \.uniqueID) { microphone in
                            ActionButton(
                                cornerRadius: 12,
                                colours: deviceButtonStyleConfig,
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
                    }).onChange(of: selectedMicrophone) { _ in
                        Task { await toggleMute() }
                    }
                    .disabled(alteringDevice[selectedMicrophone] ?? false)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: 250)

                    ActionPicker(cameraButtonText,
                                 icon: cameraIconName,
                                 input: $selectedCamera,
                                 action: toggleVideo,
                                 content: {
                        HStack {
                            Image(systemName: "video")
                                .renderingMode(.original)
                                .foregroundColor(.gray)
                            Text("Camera")
                                .foregroundColor(.gray)
                        }
                        .padding(.bottom, 5)
                        ForEach(devices.cameras, id: \.self) { camera in
                            ActionButton(
                                cornerRadius: 12,
                                colours: deviceButtonStyleConfig,
                                action: toggleVideo) {
                                    HStack {
                                        if alteringDevice[camera] ?? false {
                                            ProgressView()
                                            Spacer()
                                        } else if usingDevice[camera] ?? false {
                                            Image(systemName: "checkmark")
                                        } else {
                                            Spacer()
                                        }
                                        Text(verbatim: camera.localizedName)
                                        Spacer()
                                    }
                                }
                                .disabled(alteringDevice[camera] ?? false)
                                .aspectRatio(contentMode: .fill)
                        }
                        .frame(maxWidth: 300, alignment: .bottomTrailing)
                    })
                    .disabled(alteringDevice[selectedCamera] ?? false)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: 300)

                    Button(action: { Task { await leaveCall() }}, label: {
                        Image(systemName: "xmark")
                    })
                    .frame(width: 50, height: 50)
                    .background(.red)
                    .foregroundColor(.white)
                    .clipShape(Circle())
                    .padding(.horizontal, 10)

                }
                .edgesIgnoringSafeArea(.top)
                .padding(.bottom)

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
        alteringDevice[selectedCamera] = true
        await capture.manager!.addInput(device: selectedCamera)
        usingDevice[selectedCamera] = true
        alteringDevice[selectedCamera] = false

        await capture.manager!.startCapturing()
    }

    private func leaveCall() async {
        // Stop capturing.
        await capture.manager!.stopCapturing()

        // Remove devices.
        await capture.manager!.removeInput(device: selectedCamera)
        await capture.manager!.removeInput(device: selectedMicrophone)

        // Unbind pipeline.
        capture.videoCallback = nil
        capture.audioCallback = nil
        capture.deviceChangeCallback = nil

        // Report left.
        onLeave()
    }

    private func toggleVideo() async {
        alteringDevice[selectedCamera] = true
        usingDevice[selectedCamera] = await capture.manager!.toggleInput(device: selectedCamera)
        if usingDevice[selectedCamera]! {
            cameraButtonText = "Stop Video"
            cameraIconName = "video"
        } else {
            cameraButtonText =  "Start Video"
            cameraIconName = "video.slash"
        }
        alteringDevice[selectedCamera] = false
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

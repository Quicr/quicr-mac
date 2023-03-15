import SwiftUI
import AVFoundation
import UIKit

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

    /// Callback when call is left.
    private var onLeave: () -> Void
    private let mode: ApplicationModeBase?
    private let maxColumns: Int = 4
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
    }

    // Show a video player.
    var body: some View {
        ZStack {
            GeometryReader { geo in
                VStack {
                    // Remote videos.
                    let denom: CGFloat = .init(
                        min(maxColumns, Int(ceil(Float(render.participants.count)/2))
                        )
                    )
                    let width = (geo.size.width - 225) / denom
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: width - 100, maximum: width))]) {
                        ForEach(Array(render.participants.values)) { participant in
                            Image(uiImage: participant.decodedImage)
                                .resizable()
                                .scaledToFit()
                                .cornerRadius(12)
                        }
                    }
                    .padding([.horizontal, .top], 50)
                    .padding(.bottom, 0)
                    .cornerRadius(12)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Controls.
                    HStack {
                        Spacer()
                        ActionPicker("Mute", icon: "mic", input: $selectedMicrophone, action: toggleMute, content: {
                            ForEach(devices.audioInputs, id: \.uniqueID) { microphone in
                                Text(microphone.localizedName).tag(microphone)
                            }
                        }).onChange(of: selectedMicrophone) { _ in
                            Task {
                                alteringDevice[selectedMicrophone] = true
                                await capture.manager!.addInput(device: selectedMicrophone)
                                alteringDevice[selectedMicrophone] = false
                            }
                        }
                        .disabled(alteringDevice[selectedMicrophone] ?? false)
                        .frame(width: 150)
                        ActionPicker(cameraButtonText,
                                     icon: cameraIconName,
                                     input: $selectedCamera,
                                     action: { Task { await toggleVideo() }},
                                     content: {
                                        ForEach(devices.cameras, id: \.self) { camera in
                                            Button(role: usingDevice[camera] ?? false ? .destructive : nil,
                                                action: {
                                                    Task {
                                                        alteringDevice[camera] = true
                                                        usingDevice[camera] = await capture.manager!.toggleInput(device: camera)
                                                        alteringDevice[camera] = false
                                                    }
                                                },
                                                label: {
                                                    HStack {
                                                        Text(verbatim: camera.localizedName)
                                                        Spacer()
                                                        if alteringDevice[camera] ?? false {
                                                            ProgressView()
                                                        }
                                                    }})
                                            .disabled(alteringDevice[camera] ?? false)
                                        }
                                     }
                        )
                        .frame(width: 200)
                        Button(action: { Task { await leaveCall() }}, label: {
                            Image(systemName: "xmark")
                        })
                        .disabled(true) // TODO: Get leaveCall working better
                        .frame(width: 50, height: 50)
                        .background(.red)
                        .foregroundColor(.white)
                        .cornerRadius(50)
                        Spacer()
                    }
                    .aspectRatio(contentMode: .fit)

                    // Local video preview.
                    // PreviewView(device: $selectedCamera)
                }
            }
            .edgesIgnoringSafeArea(.top) // Only because of navigation bar forcing whole content down by 50

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
        usingDevice[selectedCamera] = await capture.manager!.toggleInput(device: selectedCamera)
        if usingDevice[selectedCamera]! {
            cameraButtonText = "Stop Video"
            cameraIconName = "video"
        } else {
            cameraButtonText =  "Start Video"
            cameraIconName = "video.slash"
        }
    }

    private func toggleMute() {}
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(mode: nil) {}
    }
}

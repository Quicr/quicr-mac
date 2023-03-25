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
    }

    // Show a video player.
    var body: some View {
        ZStack {
            GeometryReader { geo in
                VStack {
                    // Remote videos.
                    ScrollView {
                        let denom: CGFloat = .init(min(maxColumns, render.participants.count))
                        let width = geo.size.width / denom
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width))]) {
                            ForEach(Array(render.participants.values)) { participant in
                                participant.decodedImage
                                    .resizable()
                                    .scaledToFit()
                            }
                        }
                    }
                    .frame(height: geo.size.height * 0.7)

                    // Controls.
                    VStack {
                        List {
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

                        // Microphone control.
                        Picker("Microphone", selection: $selectedMicrophone) {
                            ForEach(devices.audioInputs, id: \.uniqueID) { microphone in
                                Text(microphone.localizedName).tag(microphone)
                            }
                        }.onChange(of: selectedMicrophone) { _ in
                            Task {
                                alteringDevice[selectedMicrophone] = true
                                await capture.manager!.addInput(device: selectedMicrophone)
                                alteringDevice[selectedMicrophone] = false
                            }
                        }.disabled(alteringDevice[selectedMicrophone] ?? false)
                    }
                    .padding()
                    .frame(height: geo.size.height * 0.3, alignment: .top)

                    // Local video preview.
                    // PreviewView(device: $selectedCamera)
                }
            }

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
        alteringDevice[selectedCamera] = true
        await capture.manager!.addInput(device: selectedCamera)
        usingDevice[selectedCamera] = true
        alteringDevice[selectedCamera] = false
        await capture.manager!.addInput(device: selectedMicrophone)

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
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(mode: nil) {}
    }
}

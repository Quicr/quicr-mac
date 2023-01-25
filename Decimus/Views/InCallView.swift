import SwiftUI
import AVFoundation

/// View to show when in a call.
/// Shows remote video, local self view and controls.
struct InCallView: View {
    
    /// Available input devices.
    @EnvironmentObject var devices: AudioVideoDevices
    /// Local capture manager.
    @EnvironmentObject var capture: ObservableCaptureManager
    /// Images to render.
    @EnvironmentObject var render: ObservableImage
    
    /// Currently selected camera.
    @State private var selectedCamera: AVCaptureDevice
    /// Currently selected input microphone.
    @State private var selectedMicrophone: AVCaptureDevice
    
    /// Callback when call is left.
    private var onLeave: () -> Void
    
    /// Create a new in call view.
    /// - Parameter onLeave: Callback fired when user asks to leave the call.
    init(onLeave: @escaping () -> Void) {
        self.onLeave = onLeave
        selectedCamera = AVCaptureDevice.default(for: .video)!
        selectedMicrophone = AVCaptureDevice.default(for: .audio)!
    }
    
    // Show a video player.
    var body: some View {
        VStack {
            // Remote videos.
            HStack {
                // TODO: Remote views go here.
                Image(uiImage: render.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            
            // Local video preview.
            // PreviewView(device: $selectedCamera)
            
            // Controls.
            HStack {
                // Local camera control.
                Picker("Camera", selection: $selectedCamera) {
                    ForEach(devices.cameras, id: \.self) { camera in
                        Text(camera.localizedName).tag(camera)
                    }
                }.onChange(of: selectedCamera) { _ in
                    capture.manager.selectCamera(camera: selectedCamera)
                }.onAppear() {
                    capture.manager.selectCamera(camera: selectedCamera)
                }
                
                // Microphone control.
                Picker("Microphone", selection: $selectedMicrophone) {
                    ForEach(devices.audioInputs, id: \.uniqueID) { microphone in
                        Text(microphone.localizedName).tag(microphone)
                    }
                }.onChange(of: selectedMicrophone) { _ in
                    capture.manager.selectMicrophone(microphone: selectedMicrophone)
                }
                
                // Leave.
                Button("Leave", action: onLeave)
            }
        }
    }
}

struct InCallView_Previews: PreviewProvider {
    static var previews: some View {
        InCallView(onLeave: {})
    }
}

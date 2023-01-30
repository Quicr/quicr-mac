import Foundation
import AVFoundation

/// Allows access to cameras, microphones and speakers.
class AudioVideoDevices: ObservableObject {

    @Published var audioInputs: [AVCaptureDevice]
    @Published var cameras: [AVCaptureDevice]

    init() {
        // Get all microphones and cameras.
        let cameraDiscovery: AVCaptureDevice.DiscoverySession = .init(
            deviceTypes: [
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInLiDARDepthCamera,
                .builtInTelephotoCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
                .builtInDualCamera,
                .builtInUltraWideCamera,
                .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified)
        cameras = cameraDiscovery.devices

        let microphoneDiscovery: AVCaptureDevice.DiscoverySession = .init(deviceTypes: [.builtInMicrophone],
                                                                          mediaType: .audio,
                                                                          position: .unspecified)
        audioInputs = microphoneDiscovery.devices
    }
}

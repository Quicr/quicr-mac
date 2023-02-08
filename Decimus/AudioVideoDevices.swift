import Foundation
import AVFoundation

/// Allows access to cameras, microphones and speakers.
class AudioVideoDevices: ObservableObject {

    @Published var audioInputs: [AVCaptureDevice]
    @Published var cameras: [AVCaptureDevice]

    init() {
        // Get all microphones and cameras.
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInTelephotoCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera,
            .builtInDualCamera,
            .builtInUltraWideCamera,
            .builtInWideAngleCamera
        ]
        if #available(iOS 15.4, *) {
            types.append(.builtInLiDARDepthCamera)
        }

        let cameraDiscovery: AVCaptureDevice.DiscoverySession = .init(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified)
        cameras = cameraDiscovery.devices

        let microphoneDiscovery: AVCaptureDevice.DiscoverySession = .init(deviceTypes: [.builtInMicrophone],
                                                                          mediaType: .audio,
                                                                          position: .unspecified)
        audioInputs = microphoneDiscovery.devices
    }
}

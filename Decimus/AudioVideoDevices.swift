import Foundation
import AVFoundation

struct Devices {
    static var shared = Devices()

    private(set) var devices: [AVCaptureDevice]

    init() {
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

        let cameraDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified)
        devices = cameraDiscovery.devices

        let microphoneDiscovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone],
                                                                   mediaType: .audio,
                                                                   position: .unspecified)
        devices += microphoneDiscovery.devices
    }
}

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

        let cameraDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified)
        cameras = cameraDiscovery.devices

        let microphoneDiscovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone],
                                                                   mediaType: .audio,
                                                                   position: .unspecified)
        audioInputs = microphoneDiscovery.devices
    }
}

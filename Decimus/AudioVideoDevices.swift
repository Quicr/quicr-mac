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

class Devices {
    @Published var devices: [AVCaptureDevice]

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
            .builtInWideAngleCamera,

            .builtInMicrophone
        ]
        if #available(iOS 15.4, *) {
            types.append(.builtInLiDARDepthCamera)
        }

        let deviceDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: nil,
            position: .unspecified)
        devices = deviceDiscovery.devices
    }
}

import AVFoundation

/// Allows querying this systems' video devices.
class VideoDevices: ObservableObject {
    /// The list of a available cameras.
    @Published var cameras: [AVCaptureDevice]

    /// Create and execute a query for available devices.
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
        if #available(macCatalyst 17.0, iOS 17.0, *) {
            types.append(.continuityCamera)
        }

        let cameraDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified)
        self.cameras = cameraDiscovery.devices
    }
}

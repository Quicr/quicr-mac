// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFoundation

/// Allows querying this systems' video devices.
class VideoDevices: ObservableObject {
    /// The list of a available cameras.
    @Published var cameras: [AVCaptureDevice]

    /// Create and execute a query for available devices.
    init() {
        // Get all microphones and cameras.
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera
        ]
        #if !os(macOS)
        types.append(contentsOf: [
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInTelephotoCamera,
            .builtInTripleCamera,
            .builtInTrueDepthCamera,
            .builtInDualCamera,
            .builtInUltraWideCamera
        ])
        if #available(iOS 15.4, *) {
            types.append(.builtInLiDARDepthCamera)
        }
        #endif
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

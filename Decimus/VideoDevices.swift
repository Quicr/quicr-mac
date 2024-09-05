// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFoundation

/// Allows access to cameras.
class VideoDevices: ObservableObject {
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
        if #available(macCatalyst 17.0, iOS 17.0, *) {
            types.append(.continuityCamera)
        }

        let cameraDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified)
        cameras = cameraDiscovery.devices
    }
}

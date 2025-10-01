// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import AVFoundation

struct CameraPreferencePicker: View {
    @State private var cameras: [AVCaptureDevice] = []
    @State private var selectedCamera: String = ""
    private let noPreference = "None"

    var body: some View {
        Picker("Preferred Camera", selection: $selectedCamera) {
            Text("None").tag("None")
            ForEach(self.cameras, id: \.uniqueID) {
                Text($0.localizedName)
                    .tag($0.uniqueID)
            }
        }
        .onChange(of: self.selectedCamera) {
            self.updatePreferredCamera()
        }
        .onAppear {
            self.cameras = self.discoverCameras()
            if #available(iOS 17.0, macOS 13.0, *) {
                self.selectedCamera = AVCaptureDevice.userPreferredCamera?.uniqueID ?? self.noPreference
            } else {
                self.selectedCamera = self.noPreference
            }
        }
    }

    private func discoverCameras() -> [AVCaptureDevice] {
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
        return cameraDiscovery.devices
    }

    private func updatePreferredCamera() {
        guard self.selectedCamera != self.noPreference else {
            AVCaptureDevice.userPreferredCamera = nil
            return
        }

        for camera in self.cameras where camera.uniqueID == self.selectedCamera {
            AVCaptureDevice.userPreferredCamera = camera
            break
        }
    }
}

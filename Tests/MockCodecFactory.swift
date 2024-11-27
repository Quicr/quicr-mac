// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR

class MockCodecFactory: CodecFactory {
    func makeCodecConfig(from qualityProfile: String, bitrateType: QuicR.BitrateType) -> any CodecConfig {
        VideoCodecConfig(codec: .h264, bitrate: 1000, fps: 30, width: 1920, height: 1080, bitrateType: .average)
    }
}

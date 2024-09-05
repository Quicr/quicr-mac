// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct VideoJitterBufferSettingsView: View {
    @Binding var config: VideoJitterBuffer.Config

    var body: some View {
        LabeledContent("Video Jitter Buffer Mode") {
            Picker("Video Jitter Buffer Mode", selection: $config.mode) {
                ForEach(VideoJitterBuffer.Mode.allCases) {
                    Text(String(describing: $0))
                }
            }.pickerStyle(.segmented)
        }
    }
}

#Preview {
    VideoJitterBufferSettingsView(config: .constant(.init()))
}

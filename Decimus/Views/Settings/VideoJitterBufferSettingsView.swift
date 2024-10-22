// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct VideoJitterBufferSettingsView: View {
    @Binding var config: JitterBuffer.Config

    var body: some View {
        LabeledContent("Video Jitter Buffer Mode") {
            Picker("Video Jitter Buffer Mode", selection: $config.mode) {
                ForEach(JitterBuffer.Mode.allCases) {
                    Text(String(describing: $0))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

#Preview {
    VideoJitterBufferSettingsView(config: .constant(.init()))
}

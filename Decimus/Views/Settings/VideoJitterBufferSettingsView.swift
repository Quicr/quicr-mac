import SwiftUI

struct VideoJitterBufferSettingsView: View {
    @Binding var config: JitterBuffer.Config

    var body: some View {
        LabeledContent("Video Jitter Buffer Mode") {
            Picker("Video Jitter Buffer Mode", selection: $config.mode) {
                ForEach(JitterBuffer.Mode.allCases) {
                    Text(String(describing: $0))
                }
            }.pickerStyle(.segmented)
        }
    }
}

#Preview {
    VideoJitterBufferSettingsView(config: .constant(.init()))
}

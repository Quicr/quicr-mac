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
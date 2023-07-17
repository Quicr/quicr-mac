import SwiftUI
import AVFoundation

class VideoUIView: UIView {
    override public class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
}

struct VideoView: UIViewRepresentable {
    let view: VideoUIView = .init()

    func makeUIView(context: Context) -> VideoUIView {
        view
    }

    func updateUIView(_ uiView: UIViewType, context: Context) { }
}

struct VideoView_Previews: PreviewProvider {
    static var previews: some View {
        VideoView()
    }
}

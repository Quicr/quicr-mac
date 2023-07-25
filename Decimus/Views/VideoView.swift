import SwiftUI
import AVFoundation

class VideoUIView: UIView {
    override public class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
}

struct VideoView: UIViewRepresentable {
    let view: VideoUIView = .init()
    var layer: AVSampleBufferDisplayLayer? { return view.layer as? AVSampleBufferDisplayLayer }

    func makeUIView(context: Context) -> VideoUIView {
        view.contentMode = .scaleAspectFit
        return view
    }
    func updateUIView(_ uiView: VideoUIView, context: Context) {}
}

struct VideoView_Previews: PreviewProvider {
    static var previews: some View {
        VideoView()
    }
}

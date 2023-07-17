import SwiftUI
import AVFoundation

class VideoUIView: UIView {
    override public class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        initializeLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initializeLayer()
    }

    func initializeLayer() {
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            fatalError()
        }
        layer.videoGravity = .resizeAspect
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

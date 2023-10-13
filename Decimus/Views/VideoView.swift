import SwiftUI
import AVFoundation

class VideoUIView: UIView {
    override public class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
}

enum VideoError: Error {
    case InvalidLayer
    case LayerFailed
    case LayerTimebaseFailed(Error)
}

struct VideoView: UIViewRepresentable {
    let view: VideoUIView = .init()
    var layer: AVSampleBufferDisplayLayer? { return view.layer as? AVSampleBufferDisplayLayer }

    func flush() throws {
        guard let layer = layer else {
            throw VideoError.InvalidLayer
        }

        layer.flush()

        do {
            try layer.controlTimebase?.setTime(.zero)
            try layer.controlTimebase?.setRate(1.0)
        } catch {
            throw VideoError.LayerTimebaseFailed(error)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, transform: CATransform3D?) throws {
        guard let layer = layer else {
            throw VideoError.InvalidLayer
        }

        guard layer.status != .failed else {
            layer.flush()
            throw VideoError.LayerFailed
        }

        layer.transform = transform ?? CATransform3DIdentity
        layer.enqueue(sampleBuffer)
    }

    func makeUIView(context: Context) -> VideoUIView {
        do {
            try layer?.controlTimebase = .init(sourceClock: .hostTimeClock)
            try layer?.controlTimebase?.setTime(.zero)
            try layer?.controlTimebase?.setRate(1.0)
        } catch {
            fatalError("Failed to setup layer: \(error)")
        }

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

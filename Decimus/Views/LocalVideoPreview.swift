//import SwiftUI
//import AVFoundation
//
//class PreviewControllerInternal : UIViewController {
//    
//    var session: AVCaptureSession? = nil
//    private let sessionQueue = DispatchQueue(label: "sessionQueue")
//    private var layer = AVCaptureVideoPreviewLayer()
//    
//    override func viewDidLoad() {
//        sessionQueue.async { [unowned self] in
//            self.setup()
//        }
//    }
//    
//    private func setup() {
//        let screenRect = UIScreen.main.bounds
//        layer = AVCaptureVideoPreviewLayer(session: session!)
//        layer.frame = .init(x: 0, y: 0, width: screenRect.size.width / 4, height: screenRect.size.height / 4)
//        layer.videoGravity = .resizeAspectFill
//        layer.connection?.videoOrientation = .portrait
//        
//        DispatchQueue.main.async { [weak self] in
//            self!.view.layer.addSublayer(self!.layer)
//        }
//    }
//}
//
//struct PreviewController: UIViewControllerRepresentable {
//    
//    private let session: AVCaptureSession
//    
//    init(session: AVCaptureSession) {
//        self.session = session
//    }
//    
//    func makeUIViewController(context: Context) -> UIViewController {
//        let view = PreviewControllerInternal()
//        view.session = session
//        return view
//    }
//
//    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
//}

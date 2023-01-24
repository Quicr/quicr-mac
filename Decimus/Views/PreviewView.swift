import UIKit
import SwiftUI
import AVFoundation

/// UIKit preview view to render self view of target `AVCaptureDevice`
class PreviewViewInternal: UIViewController {
    private let session: AVCaptureSession = .init()
    private let sessionQueue: DispatchQueue = .init(label: "PreviewView")
    private var previewLayer: AVCaptureVideoPreviewLayer = .init()
    var device: AVCaptureDevice
    private let screen = UIScreen.main.bounds
    private let frame: CGRect
    
    /// Create a new UIKit PreviewView for the given device.
    /// - Parameter device: The capture device to show a preview for.
    init(device: AVCaptureDevice) {
        self.device = device
        self.frame = .init(x: 0, y: 0, width: screen.width / 4, height: screen.height / 4)
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func doPreview(device: AVCaptureDevice) {
        // Push this to a session queue.
        sessionQueue.async { [unowned self] in
            // Shutdown any existing.
            session.stopRunning()
            let existingInput = try! AVCaptureDeviceInput(device: self.device)
            session.removeInput(existingInput)
            print("Removed existing device: \(existingInput.device.localizedName)")
            // TODO: Is this needed?
            DispatchQueue.main.async { [weak self] in
                self!.view.layer.sublayers?.removeAll(where: { layer in
                    return layer == self!.previewLayer
                })
            }
            
            // Add the input to the session if not already.
            let videoDeviceInput = try! AVCaptureDeviceInput(device: device)
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
            }
            self.device = device
            print("Updated to device: \(self.device.localizedName)")
            
            // Create preview.
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.frame = frame
            previewLayer.videoGravity = AVLayerVideoGravity.resizeAspect
            
            // Add the preview layer to this view on the main thread.
            DispatchQueue.main.async { [weak self] in
                    self!.view.layer.addSublayer(self!.previewLayer)
            }
            
            // Start the capture session.
            guard session.isRunning else {
                session.startRunning()
                return
            }
        }
    }
    
    override func viewDidLoad() {
        doPreview(device: self.device)
    }
    
     override func willTransition(to newCollection: UITraitCollection, with coordinator: UIViewControllerTransitionCoordinator) {
        self.previewLayer.frame = frame
    }
    
    func update(device: AVCaptureDevice) {
        guard device.uniqueID != self.device.uniqueID else {
            print("Ignoring matching device")
            return
        }
        doPreview(device: device)
    }
}

/// Preview a video `AVCaptureDevice`. SwiftUI wrapper for `PreviewControllerInternal`.
struct PreviewView: UIViewControllerRepresentable {
    
    @Binding private var device: AVCaptureDevice
    
    /// Create a new `PreviewView`.
    /// - Parameter device: The device to preview.
    init(device: Binding<AVCaptureDevice>) {
        self._device = device
        print("Init PreviewView. Current camera: \(self.device.localizedName)")
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        print("Make PreviewView. Current camera: \(self.device.localizedName)")
        return PreviewViewInternal(device: device)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        print("Update PreviewView. Current camera: \(self.device.localizedName)")
        
        let preview: PreviewViewInternal = uiViewController as! PreviewViewInternal
        guard preview.device == self.device else {
            print("Updating target device to: \(self.device.localizedName)")
            preview.update(device: self.device)
            return
        }
    }
    
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        print("Should dismantle")
    }
}

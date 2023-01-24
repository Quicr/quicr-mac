import AVFoundation

/// Manages local media capture.
class CaptureManager {
    
    let session: AVCaptureSession = .init()
    var selectedCamera: AVCaptureDevice? = nil
    var selectedMicrophone: AVCaptureDevice? = nil
    private let sessionQueue: DispatchQueue = .init(label: "CaptureManager")
    
    /// Start capturing from the target camera.
    /// - Parameter camera: The target `AVCaptureDevice`.
    func selectCamera(camera: AVCaptureDevice) {
        print("Using camera: \(camera.localizedName)")
        
        // Add this device to the session.
        let input: AVCaptureDeviceInput = try! .init(device: camera)
        if !session.canAddInput(input) {
            print("Input already added")
        }
        
        // Run the session.
        if !session.isRunning {
            sessionQueue.async {
                self.session.startRunning()
                print("Started capture session")
            }
        }
    }
    
    /// Start capturing from the target microphone.
    /// - Parameter microphone: The target audio input device.
    func selectMicrophone(microphone: AVCaptureDevice) {
        print("Using microphone: \(microphone.localizedName)")
    }
}

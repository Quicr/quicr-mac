import AVFoundation

/// Manages local media capture.
class CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    /// Callback of raw camera frames.
    typealias CameraFrameCallback = (CMSampleBuffer) -> ()
    
    let session: AVCaptureSession = .init()
    let callback: CameraFrameCallback
    private let sessionQueue: DispatchQueue = .init(label: "CaptureManager")
    private var inputs: [AVCaptureDevice : AVCaptureDeviceInput] = [:]

    init(callback: @escaping CameraFrameCallback) {
        self.callback = callback
        super.init()
        session.beginConfiguration()
        let videoOutput: AVCaptureVideoDataOutput = .init()
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)
        session.commitConfiguration()
    }
    
    func stopCapturing() {
        guard session.isRunning else { fatalError("Shouldn't call stopCapturing when not running") }
        session.stopRunning()
    }
    
    /// Start capturing from the target camera.
    /// - Parameter camera: The target `AVCaptureDevice`.
    func selectCamera(camera: AVCaptureDevice) {
        print("CaptureManager => Using camera: \(camera.localizedName)")
        
        // Add this device to the session.
        session.beginConfiguration()
        let input: AVCaptureDeviceInput = try! .init(device: camera)
        inputs[camera] = input
        guard session.canAddInput(input) else {
            print("Input already added?")
            return
        }
        session.addInput(input)
        session.commitConfiguration()
        
        // Run the session.
        guard session.isRunning else {
            sessionQueue.async {
                self.session.startRunning()
            }
            return
        }
    }
    
    func removeInput(device: AVCaptureDevice) {
        let input = inputs[device]
        guard input != nil else { return }
        print("CaptureManager => Removing input for \(device.localizedName)")
        self.session.removeInput(input!)
    }
    
    /// Fires when a frame is available.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        callback(sampleBuffer)
    }
    
    /// This callback fires if a frame was dropped.
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("CaptureManager => Frame dropped!")
    }
    
    /// Start capturing from the target microphone.
    /// - Parameter microphone: The target audio input device.
    func selectMicrophone(microphone: AVCaptureDevice) {
        print("CaptureManager => Using microphone: \(microphone.localizedName)")
    }
}

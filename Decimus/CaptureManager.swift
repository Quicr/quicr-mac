import AVFoundation

/// Manages local media capture.
class CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    /// Callback of raw camera frames.
    typealias CameraFrameCallback = (CMSampleBuffer) -> ()
    
    let session: AVCaptureSession = .init()
    let callback: CameraFrameCallback
    private let sessionQueue: DispatchQueue = .init(label: "CaptureManager")

    init(callback: @escaping CameraFrameCallback) {
        self.callback = callback
        super.init()
        session.beginConfiguration()
        let videoOutput: AVCaptureVideoDataOutput = .init()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        // videoOutput.connection(with: .video)?.isEnabled = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        // TODO: Do we need to specify this?
        // videoOutput.videoSettings = [ kCVPixelBufferPixelFormatTypeKey as String: videoOutput.availableVideoPixelFormatTypes[0]]
        guard session.canAddOutput(videoOutput) else { return }
        session.sessionPreset = .medium
        session.addOutput(videoOutput)
        session.commitConfiguration()
    }
    
    /// Start capturing from the target camera.
    /// - Parameter camera: The target `AVCaptureDevice`.
    func selectCamera(camera: AVCaptureDevice) {
        print("CaptureManager => Using camera: \(camera.localizedName)")
        
        // Add this device to the session.
        session.beginConfiguration()
        let input: AVCaptureDeviceInput = try! .init(device: camera)
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

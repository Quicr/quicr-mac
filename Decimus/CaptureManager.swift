import AVFoundation

/// Manages local media capture.
class CaptureManager: NSObject,
                      AVCaptureVideoDataOutputSampleBufferDelegate,
                      AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Callback of raw camera frames.
    typealias MediaCallback = (UInt32, CMSampleBuffer) -> Void

    let session: AVCaptureSession
    let cameraFrameCallback: MediaCallback
    let audioFrameCallback: MediaCallback
    private let sessionQueue: DispatchQueue = .init(label: "CaptureManager")
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureOutput: AVCaptureDevice] = [:]

    private let videoOutput: AVCaptureVideoDataOutput = .init()
    private let audioOutput: AVCaptureAudioDataOutput = .init()

    init(cameraCallback: @escaping MediaCallback, audioCallback: @escaping MediaCallback) {
        self.cameraFrameCallback = cameraCallback
        self.audioFrameCallback = audioCallback

        // Audio configuration.
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoChat)
        } catch {
            fatalError(error.localizedDescription)
        }
        session = .init()
        session.automaticallyConfiguresApplicationAudioSession = false
        super.init()
        session.beginConfiguration()
        session.sessionPreset = .medium

        // Video output.
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        // Audio output.
        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(audioOutput) else { return }
        session.addOutput(audioOutput)

        session.commitConfiguration()
    }

    func stopCapturing() {
        guard session.isRunning else { fatalError("Shouldn't call stopCapturing when not running") }
        session.stopRunning()
    }

    /// Start capturing from the target device.
    /// - Parameter device: The target capture device.
    func addInput(device: AVCaptureDevice) {
        print("CaptureManager => Adding capture device: \(device.localizedName)")

        // Add this device to the session.
        session.beginConfiguration()
        if let input: AVCaptureDeviceInput = try? .init(device: device) {
            inputs[device] = input
            guard session.canAddInput(input) else {
                print("[CaptureManager] Input already added: \(device)")
                return
            }
            session.addInput(input)
        }
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
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var device: AVCaptureDevice?
        for input in connection.inputPorts {
            if let inputDevice = input.input as? AVCaptureDeviceInput {
                guard device == nil else { fatalError("Found more than one matching device") }
                device = inputDevice.device
            } else {
                fatalError("Bad device id?")
            }
        }

        switch output {
        case videoOutput:
            cameraFrameCallback(UInt32(truncatingIfNeeded: device?.uniqueID.hash ?? 0), sampleBuffer)
        case audioOutput:
            audioFrameCallback(UInt32(truncatingIfNeeded: device?.uniqueID.hash ?? 0), sampleBuffer)
        default:
            fatalError("Unexpected output in CaptureManager")
        }
    }

    /// This callback fires if a frame was dropped.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        print("CaptureManager => Frame dropped!")
    }
}

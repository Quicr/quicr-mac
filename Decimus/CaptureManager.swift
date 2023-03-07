import AVFoundation

public extension AVCaptureDevice {
    var id: UInt32 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

/// Manages local media capture.
class CaptureManager: NSObject,
                      AVCaptureVideoDataOutputSampleBufferDelegate,
                      AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Describe events that can happen to devices.
    enum DeviceEvent { case added; case removed }

    /// Callback of raw camera frames.
    typealias MediaCallback = (UInt32, CMSampleBuffer) -> Void
    /// Callback of a device event.
    typealias DeviceChangeCallback = (AVCaptureDevice, DeviceEvent) -> Void

    let session: AVCaptureMultiCamSession
    let cameraFrameCallback: MediaCallback
    let audioFrameCallback: MediaCallback
    let deviceChangedCallback: DeviceChangeCallback
    private let sessionQueue: DispatchQueue = .init(label: "CaptureManager", target: .global(qos: .userInitiated))
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureVideoDataOutput: AVCaptureDevice] = [:]
    private var connections: [AVCaptureDevice: AVCaptureConnection] = [:]

    private let audioOutput: AVCaptureAudioDataOutput = .init()
    private let errorHandler: ErrorWriter

    init(cameraCallback: @escaping MediaCallback,
         audioCallback: @escaping MediaCallback,
         deviceChangeCallback: @escaping DeviceChangeCallback,
         errorHandler: ErrorWriter) {
        self.cameraFrameCallback = cameraCallback
        self.audioFrameCallback = audioCallback
        self.deviceChangedCallback = deviceChangeCallback
        self.errorHandler = errorHandler

        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            fatalError("Multicam not supported on this device")
        }

        session = .init()
        super.init()
        sessionQueue.async {
            self.setup()
        }
    }

    private func setup() {
        // Audio configuration.
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoChat)
        } catch {
            errorHandler.writeError(message: error.localizedDescription)
        }

        // Create the capture session.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()

        // Audio output.
        audioOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(audioOutput) else { return }
        session.addOutputWithNoConnections(audioOutput)

        session.commitConfiguration()
    }

    func usingInput(device: AVCaptureDevice) -> Bool {
        inputs[device] != nil
    }

    func startCapturing() {
        if session.isRunning { return }
        self.session.startRunning()
    }

    func stopCapturing() {
        guard session.isRunning else {
            errorHandler.writeError(message: "Shouldn't call StopCapturing when not running")
            return
        }
        sessionQueue.async {
            self.session.stopRunning()
        }
    }

    func toggleInput(device: AVCaptureDevice) {
        if inputs[device] != nil {
            removeInput(device: device)
            return
        }
        addInput(device: device)
    }

    private func addMicrophone(device: AVCaptureDevice) {
        guard device.deviceType == .builtInMicrophone else {
            errorHandler.writeError(message: "addMicrophone must be called on a microphone")
            return
        }

        guard let microphone: AVCaptureDeviceInput = try? .init(device: device) else {
            errorHandler.writeError(message: "Couldn't create input for microphone")
            return
        }

        guard session.canAddInput(microphone) else {
            errorHandler.writeError(message: "Couldn't add microphone")
            return
        }
        session.addInput(microphone)
        inputs[device] = microphone
    }

    private func addCamera(device: AVCaptureDevice) {
        do {
            // Device config.
            try device.lockForConfiguration()

            // Pick the highest quality multi-cam format.
            for format in device.formats.reversed() where format.isMultiCamSupported &&
                                                      format.isHighestPhotoQualitySupported {
                device.activeFormat = format
                break
            }
            device.unlockForConfiguration()
        } catch {
            errorHandler.writeError(message: "Couldn't configure camera: \(error.localizedDescription)")
        }

        // Add an output for this device.
        let videoOutput: AVCaptureVideoDataOutput = .init()
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else {
            errorHandler.writeError(message: "Output already added: \(device.localizedName)")
            return
        }
        session.addOutputWithNoConnections(videoOutput)
        outputs[videoOutput] = device

        // Add this device to the session.
        guard let input: AVCaptureDeviceInput = try? .init(device: device) else {
            errorHandler.writeError(message: "Couldn't create input for camera: \(device.localizedName)")
            return
        }

        inputs[device] = input
        guard session.canAddInput(input) else {
            errorHandler.writeError(message: "Couldn't add input for camera: \(device.localizedName)")
            return
        }
        session.addInputWithNoConnections(input)

        // Setup the connection.
        let connection: AVCaptureConnection = .init(inputPorts: input.ports, output: videoOutput)
        session.addConnection(connection)
        connections[device] = connection
    }

    /// Start capturing from the target device.
    /// - Parameter device: The target capture device.
    func addInput(device: AVCaptureDevice) {
        sessionQueue.async { [self] in
            print("CaptureManager => Adding capture device: \(device.localizedName)")
            session.beginConfiguration()
            if device.deviceType == .builtInMicrophone {
                addMicrophone(device: device)
            } else {
                addCamera(device: device)
            }
            session.commitConfiguration()

            // Run the session
            if !session.isRunning {
                session.startRunning()
            }

            // Notify.
            deviceChangedCallback(device, .added)
        }
    }

    func removeInput(device: AVCaptureDevice) {
        sessionQueue.async { [self] in
            let input = inputs.removeValue(forKey: device)
            guard input != nil else {
                errorHandler.writeError(message: "Unexpectedly asked to remove missing input: \(device.localizedName)")
                return
            }
            session.beginConfiguration()
            let connection = connections.removeValue(forKey: device)
            if connection != nil {
                session.removeConnection(connection!)
            }
            session.removeInput(input!)
            for output in outputs where output.value == device {
                outputs.removeValue(forKey: output.key)
                output.key.setSampleBufferDelegate(nil, queue: nil)
            }
            session.commitConfiguration()
            print("CaptureManager => Removing input for \(device.localizedName)")
            deviceChangedCallback(device, .removed)
        }
    }

    /// Fires when a frame is available.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Get the device this frame was for.
        var device: AVCaptureDevice?
        for input in connection.inputPorts {
            // We're only interested in A/V.
            if input.mediaType != .video && input.mediaType != .audio {
                continue
            }
            guard let inputDevice = input.input as? AVCaptureDeviceInput else {
                errorHandler.writeError(message: "Couldn't find device for output")
                return
            }
            device = inputDevice.device
            break
        }

        // Callback this media sample.
        if output == audioOutput {
            audioFrameCallback(UInt32(truncatingIfNeeded: device!.id), sampleBuffer)
        } else {
            cameraFrameCallback(UInt32(truncatingIfNeeded: device!.id), sampleBuffer)
        }
    }

    /// This callback fires if a frame was dropped.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // TODO: Get reason.
        print("CaptureManager => Frame dropped!")
    }
}

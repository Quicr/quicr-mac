import AVFoundation
import UIKit

public extension AVCaptureDevice {
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

/// Manages local media capture.
actor CaptureManager {

    /// Describe events that can happen to devices.
    enum DeviceEvent { case added; case removed }

    /// Callback of raw camera frames.
    typealias MediaCallback = (SourceIDType, CMSampleBuffer) -> Void
    /// Callback of a device event.
    typealias DeviceChangeCallback = (AVCaptureDevice, DeviceEvent) -> Void

    let session: AVCaptureMultiCamSession
    let cameraFrameCallback: MediaCallback
    let audioFrameCallback: MediaCallback
    let deviceChangedCallback: DeviceChangeCallback
    private let sessionQueue: DispatchQueue = .init(label: "CaptureManager", target: .global(qos: .userInitiated))
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureOutput: AVCaptureDevice] = [:]
    private var connections: [AVCaptureDevice: AVCaptureConnection] = [:]
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

        // Audio configuration.
        do {
            try AVAudioSession.configureForDecimus()
        } catch {
            errorHandler.writeError(message: error.localizedDescription)
        }

        // Create the capture session.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()

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
        self.session.stopRunning()
    }

    func toggleInput(device: AVCaptureDevice) -> Bool {
        guard let connection = self.connections[device] else { fatalError() }
        connection.isEnabled.toggle()
        return connection.isEnabled
    }

    private func addMicrophone(device: AVCaptureDevice, delegate: AVCaptureAudioDataOutputSampleBufferDelegate) {
        guard device.deviceType == .builtInMicrophone else {
            errorHandler.writeError(message: "addMicrophone must be called on a microphone")
            return
        }

        guard let microphone: AVCaptureDeviceInput = try? .init(device: device) else {
            errorHandler.writeError(message: "Couldn't create input for microphone")
            return
        }

        let audioOutput: AVCaptureAudioDataOutput = .init()
        audioOutput.setSampleBufferDelegate(delegate, queue: sessionQueue)
        addIO(device: device, input: microphone, output: audioOutput)
    }

    private func addCamera(device: AVCaptureDevice, delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
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

        guard let camera: AVCaptureDeviceInput = try? .init(device: device) else {
            errorHandler.writeError(message: "Couldn't create input for camera")
            return
        }

        // Add an output for this device.
        let videoOutput: AVCaptureVideoDataOutput = .init()
        videoOutput.setSampleBufferDelegate(delegate, queue: sessionQueue)
        addIO(device: device, input: camera, output: videoOutput)
    }

    private func addIO(device: AVCaptureDevice, input: AVCaptureDeviceInput, output: AVCaptureOutput) {
        guard session.canAddOutput(output) else {
            errorHandler.writeError(message: "Output already added: \(device.localizedName)")
            return
        }
        session.addOutputWithNoConnections(output)
        outputs[output] = device

        // Add this device to the session.
        guard let input: AVCaptureDeviceInput = try? .init(device: device) else {
            errorHandler.writeError(message: "Couldn't create input for device: \(device.localizedName)")
            return
        }

        inputs[device] = input
        guard session.canAddInput(input) else {
            errorHandler.writeError(message: "Couldn't add input for device: \(device.localizedName)")
            return
        }
        session.addInputWithNoConnections(input)

        // Setup the connection.
        let connection: AVCaptureConnection = .init(inputPorts: input.ports, output: output)
        session.addConnection(connection)
        connections[device] = connection
    }

    /// Start capturing from the target device.
    /// - Parameter device: The target capture device.
    func addInput(device: AVCaptureDevice,
                  delegate: AVCaptureVideoDataOutputSampleBufferDelegate?,
                  audioDelegate: AVCaptureAudioDataOutputSampleBufferDelegate?) {
        // Notify upfront.
        print("CaptureManager => Adding capture device: \(device.localizedName)")
        deviceChangedCallback(device, .added)

        // Add.
        session.beginConfiguration()
        if device.deviceType == .builtInMicrophone {
            addMicrophone(device: device, delegate: audioDelegate!)
        } else {
            addCamera(device: device, delegate: delegate!)
        }
        session.commitConfiguration()

        // Run the session
        if !session.isRunning {
            session.startRunning()
        }
    }

    func removeInput(device: AVCaptureDevice) {
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
        }
        session.commitConfiguration()
        print("CaptureManager => Removing input for \(device.localizedName)")
        deviceChangedCallback(device, .removed)
    }

    func isMuted(device: AVCaptureDevice) -> Bool {
        guard let connection = connections[device] else {
            fatalError()
        }
        return connection.isEnabled
    }
}

extension UIDeviceOrientation {
    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
}

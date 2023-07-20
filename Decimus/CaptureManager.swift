import AVFoundation
import UIKit

public extension AVCaptureDevice {
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

protocol FrameListener: AVCaptureVideoDataOutputSampleBufferDelegate {
    var queue: DispatchQueue { get }
}

/// Manages local media capture.
actor CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Describe events that can happen to devices.
    enum DeviceEvent { case added; case removed }

    /// Callback of a device event.
    typealias DeviceChangeCallback = (AVCaptureDevice, DeviceEvent) -> Void

    let session: AVCaptureMultiCamSession
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureOutput: AVCaptureDevice] = [:]
    private var connections: [AVCaptureDevice: AVCaptureConnection] = [:]
    private var multiVideoDelegate: [AVCaptureDevice: [FrameListener]] = [:]
    private let queue: DispatchQueue = .init(label: "com.cisco.quicr.Decimus.CaptureManager", qos: .userInteractive)

    init(value: Void? = nil) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw "Multicam not supported on this device"
        }

        session = .init()

        // Audio configuration.
        try AVAudioSession.configureForDecimus()

        // Create the capture session.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()

        session.commitConfiguration()
    }

    func devices() -> [AVCaptureDevice] {
        return Array(connections.keys)
    }

    func activeDevices() throws -> [AVCaptureDevice] {
        return Array(try connections.keys.filter { try !isMuted(device: $0) })
    }

    func usingInput(device: AVCaptureDevice) -> Bool {
        inputs[device] != nil
    }

    func startCapturing() {
        if session.isRunning { return }
        self.session.startRunning()
    }

    func stopCapturing() throws {
        guard session.isRunning else {
            throw "Shouldn't call StopCapturing when not running"
        }
        self.session.stopRunning()
    }

    func toggleInput(device: AVCaptureDevice) -> Bool {
        guard let connection = self.connections[device] else { fatalError() }
        connection.isEnabled.toggle()
        return connection.isEnabled
    }

    private func addMicrophone(device: AVCaptureDevice,
                               delegate: AVCaptureAudioDataOutputSampleBufferDelegate,
                               queue: DispatchQueue) throws {
        guard device.deviceType == .builtInMicrophone else {
            throw "addMicrophone must be called on a microphone"
        }

        let microphone: AVCaptureDeviceInput = try .init(device: device)
        let audioOutput: AVCaptureAudioDataOutput = .init()
        audioOutput.setSampleBufferDelegate(delegate, queue: queue)
        try addIO(device: device, input: microphone, output: audioOutput)
    }

    private func addCamera(device: AVCaptureDevice, delegate: FrameListener) throws {
        // Device is already setup, add this delegate.
        if var cameraFrameListeners = self.multiVideoDelegate[device] {
            cameraFrameListeners.append(delegate)
            self.multiVideoDelegate[device] = cameraFrameListeners
            return
        }

        // Setup device.
        try device.lockForConfiguration()

        // Pick the highest quality multi-cam format.
        for format in device.formats.reversed() where format.isMultiCamSupported &&
                                                  format.isHighestPhotoQualitySupported {
            device.activeFormat = format
            break
        }
        device.unlockForConfiguration()

        // Add an output for this device.
        let camera: AVCaptureDeviceInput = try .init(device: device)
        let videoOutput: AVCaptureVideoDataOutput = .init()
        videoOutput.setSampleBufferDelegate(self, queue: self.queue)
        try addIO(device: device, input: camera, output: videoOutput)
        self.multiVideoDelegate[device] = [delegate]
    }

    private func addIO(device: AVCaptureDevice, input: AVCaptureDeviceInput, output: AVCaptureOutput) throws {
        guard session.canAddOutput(output) else {
            throw "Output already added: \(device.localizedName)"
        }
        try session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.addOutputWithNoConnections(output)
        outputs[output] = device

        // Add this device to the session.
        let input: AVCaptureDeviceInput = try .init(device: device)
        inputs[device] = input
        guard session.canAddInput(input) else {
            throw "Couldn't add input for device: \(device.localizedName)"
        }
        session.addInputWithNoConnections(input)

        // Setup the connection.
        let connection: AVCaptureConnection = .init(inputPorts: input.ports, output: output)
        session.addConnection(connection)
        connections[device] = connection
    }

    func addInput(_ publication: AVCaptureDevicePublication) throws {
        guard let device = publication.device else {
            fatalError("CaptureManager => Failed to add device (device was nil)")
        }

        // Notify upfront.
        print("CaptureManager => Adding capture device: \(device.localizedName)")

        // Add.
        if device.deviceType == .builtInMicrophone {
            throw "Don't use CaptureManager for audio input"
        }

        guard let videoDelegate = publication as? FrameListener else {
            fatalError("CaptureManager => Failed to add input: Publication is not a FrameListener")
        }
        try addCamera(device: device, delegate: videoDelegate)

        // Run the session
        if !session.isRunning {
            session.startRunning()
        }
    }

    func removeInput(device: AVCaptureDevice) throws {
        let input = inputs.removeValue(forKey: device)
        guard input != nil else {
            throw "Unexpectedly asked to remove missing input: \(device.localizedName)"
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
    }

    func isMuted(device: AVCaptureDevice) throws -> Bool {
        guard let connection = connections[device] else {
            throw "Connection not found for \(device.localizedName)"
        }
        return !connection.isEnabled
    }

    private func getDelegate(output: AVCaptureOutput) -> [FrameListener] {
        guard let device = self.outputs[output],
              let subscribers = self.multiVideoDelegate[device] else {
            return []
        }
        return subscribers
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        Task(priority: .high) {
            let cameraFrameListeners = await getDelegate(output: output)
            for listener in cameraFrameListeners {
                listener.queue.async {
                    listener.captureOutput?(output, didOutput: sampleBuffer, from: connection)
                }
            }
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didDrop sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        Task(priority: .high) {
            let cameraFrameListeners = await getDelegate(output: output)
            for listener in cameraFrameListeners {
                listener.queue.async {
                    listener.captureOutput?(output, didOutput: sampleBuffer, from: connection)
                }
            }
        }
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

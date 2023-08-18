import AVFoundation
import UIKit
import os

public extension AVCaptureDevice {
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

protocol FrameListener: AVCaptureVideoDataOutputSampleBufferDelegate {
    var queue: DispatchQueue { get }
    var device: AVCaptureDevice { get }
}

enum CaptureManagerError: Error {
    case multicamNotSuported
    case badSessionState
    case missingInput(AVCaptureDevice)
    case couldNotAdd(AVCaptureDevice)
    case noAudio
}

/// Manages local media capture.
actor CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: CaptureManager.self)
    )

    /// Describe events that can happen to devices.
    enum DeviceEvent { case added; case removed }

    /// Callback of a device event.
    typealias DeviceChangeCallback = (AVCaptureDevice, DeviceEvent) -> Void

    private let session: AVCaptureMultiCamSession
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureOutput: AVCaptureDevice] = [:]
    private var connections: [AVCaptureDevice: AVCaptureConnection] = [:]
    private var multiVideoDelegate: [AVCaptureDevice: [FrameListener]] = [:]
    private let queue: DispatchQueue = .init(label: "com.cisco.quicr.Decimus.CaptureManager", qos: .userInteractive)
    private let notifier: NotificationCenter = .default

    init(value: Void? = nil) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CaptureManagerError.multicamNotSuported
        }
        session = .init()
        session.automaticallyConfiguresApplicationAudioSession = false
        super.init()
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

    func startCapturing() throws {
        guard !session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        queue.async {
            self.session.startRunning()
        }
    }

    @Sendable
    private nonisolated func onStartFailure(notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            Self.logger.error("AVCaptureSession failed for unknown reason")
            return
        }
        Self.logger.error("AVCaptureSession failure: \(error.localizedDescription)")
    }

    func stopCapturing() throws {
        guard session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        self.session.stopRunning()
    }

    func toggleInput(device: AVCaptureDevice) -> Bool {
        guard let connection = self.connections[device] else { fatalError() }
        connection.isEnabled.toggle()
        return connection.isEnabled
    }

    private func addCamera(listener: FrameListener) throws {
        // Device is already setup, add this delegate.
        let device = listener.device
        if var cameraFrameListeners = self.multiVideoDelegate[device] {
            cameraFrameListeners.append(listener)
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

        // Prepare IO.
        let input: AVCaptureDeviceInput = try .init(device: device)
        let output: AVCaptureVideoDataOutput = .init()
        let lossless420 = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
        if output.availableVideoPixelFormatTypes.contains(where: {
            $0 == lossless420
        }) {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: lossless420
            ]
        }
        output.setSampleBufferDelegate(self, queue: self.queue)
        guard session.canAddInput(input),
              session.canAddOutput(output) else {
            throw CaptureManagerError.couldNotAdd(device)
        }
        let connection: AVCaptureConnection = .init(inputPorts: input.ports, output: output)

        // Apply these changes.
        session.beginConfiguration()
        session.addOutputWithNoConnections(output)
        session.addInputWithNoConnections(input)
        session.addConnection(connection)

        // Done.
        session.commitConfiguration()
        outputs[output] = device
        inputs[device] = input
        connections[device] = connection
        self.multiVideoDelegate[device] = [listener]
    }

    func addInput(_ listener: FrameListener) throws {
        Self.logger.info("Adding capture device: \(listener.device.localizedName)")

        if listener.device.deviceType == .builtInMicrophone {
            throw CaptureManagerError.noAudio
        }

        try addCamera(listener: listener)

        // Run the session
        if !session.isRunning {
            session.startRunning()
        }
    }

    func removeInput(device: AVCaptureDevice) throws {
        let input = inputs.removeValue(forKey: device)
        guard input != nil else {
            throw CaptureManagerError.missingInput(device)
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
        Self.logger.info("Removing input for \(device.localizedName)")
    }

    func isMuted(device: AVCaptureDevice) throws -> Bool {
        guard let connection = connections[device] else {
            throw CaptureManagerError.missingInput(device)
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

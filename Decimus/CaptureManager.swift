import AVFoundation
import UIKit

public extension AVCaptureDevice {
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
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
    private var multiVideoDelegate: [AVCaptureDevice: [AVCaptureVideoDataOutputSampleBufferDelegate]] = [:]
    private let errorHandler: ErrorWriter
    private let queue: DispatchQueue = .init(label: "com.cisco.quicr.Decimus.CaptureManager", qos: .userInteractive)

    init(errorHandler: ErrorWriter) {
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

    #if !os(tvOS)
    private func addMicrophone(device: AVCaptureDevice,
                               delegate: AVCaptureAudioDataOutputSampleBufferDelegate,
                               queue: DispatchQueue) {
        guard device.deviceType == .builtInMicrophone else {
            errorHandler.writeError(message: "addMicrophone must be called on a microphone")
            return
        }

        guard let microphone: AVCaptureDeviceInput = try? .init(device: device) else {
            errorHandler.writeError(message: "Couldn't create input for microphone")
            return
        }

        let audioOutput: AVCaptureAudioDataOutput = .init()
        audioOutput.setSampleBufferDelegate(delegate, queue: queue)
        addIO(device: device, input: microphone, output: audioOutput)
    }
    #endif

    private func addCamera(device: AVCaptureDevice,
                           delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        // Device is already setup, add this delegate.
        if var subscriptions = self.multiVideoDelegate[device] {
            subscriptions.append(delegate)
            self.multiVideoDelegate[device] = subscriptions
            return
        }

        // Setup device.
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
        videoOutput.setSampleBufferDelegate(self, queue: self.queue)
        addIO(device: device, input: camera, output: videoOutput)
        self.multiVideoDelegate[device] = [delegate]
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
                  delegateCapture: PublicationCaptureDelegate?,
                  queue: DispatchQueue) {
        // Notify upfront.
        print("CaptureManager => Adding capture device: \(device.localizedName)")

        // Add.
        session.beginConfiguration()

#if !os(tvOS)
        if device.deviceType == .builtInMicrophone {
            guard let audioDelegate = delegateCapture as? AVCaptureAudioDataOutputSampleBufferDelegate else {
                fatalError("CaptureManager => Failed to add input: Publication capture delegate is not AVCaptureAudioDataOutputSampleBufferDelegate")
            }
            addMicrophone(device: device, delegate: audioDelegate, queue: queue)

            session.commitConfiguration()

            // Run the session
            if !session.isRunning {
                session.startRunning()
            }

            return
        }
#endif

        guard let videoDelegate = delegateCapture as? AVCaptureVideoDataOutputSampleBufferDelegate else {
            fatalError("CaptureManager => Failed to add input: Publication capture delegate is not AVCaptureVideoDataOutputSampleBufferDelegate")
        }
        addCamera(device: device, delegate: videoDelegate)
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
    }

    func isMuted(device: AVCaptureDevice) -> Bool {
        guard let connection = connections[device] else {
            fatalError()
        }
        return connection.isEnabled
    }

    private func getDelegate(output: AVCaptureOutput) -> [AVCaptureVideoDataOutputSampleBufferDelegate] {
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
            let subscriptions = await getDelegate(output: output)
            await withTaskGroup(of: Void.self, body: { group in
                for subscriber in subscriptions {
                    group.addTask {
                        subscriber.captureOutput?(output, didOutput: sampleBuffer, from: connection)
                    }
                }
            })
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didDrop sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        Task(priority: .high) {
            let subscriptions = await getDelegate(output: output)
            await withTaskGroup(of: Void.self, body: { group in
                for subscriber in subscriptions {
                    group.addTask {
                        subscriber.captureOutput?(output, didDrop: sampleBuffer, from: connection)
                    }
                }
            })
        }
    }
}

#if !os(tvOS)
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
#endif

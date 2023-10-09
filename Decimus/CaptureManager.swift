import AVFoundation
import UIKit
import os

public extension AVCaptureDevice {
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

/// Represents a party interested in video frames.
protocol FrameListener: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// The DispatchQueue to receive video frames on.
    var queue: DispatchQueue { get }
    /// The device of interest.
    var device: AVCaptureDevice { get }
    /// Configuration of desired frames / format.
    var codec: VideoCodecConfig { get }
}

/// Possible capture manager errors.
enum CaptureManagerError: Error {
    /// This device does not support a multicam session.
    case multicamNotSuported
    /// The caller has attempted to use the session in an invalid way.
    case badSessionState
    /// An operation has been attempted on the given device, which is not managed by the session.
    case missingInput(AVCaptureDevice)
    /// Failed to add the given device to this capture session.
    case couldNotAdd(AVCaptureDevice)
    /// CaptureManager should not be used for audio. See: DecimusAudioEngine.
    case noAudio
    /// This operation should only be called from the main thread.
    case mainThread
}

/// Manages local media capture.
class CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private actor _Measurement: Measurement {
        var name: String = "CaptureManager"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var capturedFrames: UInt64 = 0
        private var dropped: UInt64 = 0
        private var captureDelay: Double = 0

        init(submitter: MetricsSubmitter) {
            Task {
                await submitter.register(measurement: self)
            }
        }

        func droppedFrame(timestamp: Date?) {
            self.dropped += 1
            record(field: "droppedFrames", value: self.dropped as AnyObject, timestamp: timestamp)
        }

        func capturedFrame(delayMs: Double?, timestamp: Date?) {
            self.capturedFrames += 1
            record(field: "capturedFrames", value: self.capturedFrames as AnyObject, timestamp: timestamp)
            if let delayMs = delayMs {
                record(field: "captureDelay", value: delayMs as AnyObject, timestamp: timestamp)
            }
        }
    }

    private static let logger = DecimusLogger(CaptureManager.self)

    /// Describe events that can happen to devices.
    enum DeviceEvent { case added; case removed }

    /// Callback of a device event.
    typealias DeviceChangeCallback = (AVCaptureDevice, DeviceEvent) -> Void

    private let session: AVCaptureMultiCamSession
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureOutput: AVCaptureDevice] = [:]
    private var startTime: [AVCaptureOutput: Date] = [:]
    private var connections: [AVCaptureDevice: AVCaptureConnection] = [:]
    private var multiVideoDelegate: [AVCaptureDevice: [FrameListener]] = [:]
    private let queue: DispatchQueue = .init(label: "com.cisco.quicr.Decimus.CaptureManager", qos: .userInteractive)
    private let notifier: NotificationCenter = .default
    private var observer: NSObjectProtocol?
    private let measurement: _Measurement?
    private var lastCapture: Date?
    private let granularMetrics: Bool
    private let warmupTime: TimeInterval = 0.75

    /// Create a new CaptureManager.
    /// - Parameter metricsSubmitter Optionally, an object to submit metrics through.
    /// - Parameter granularMetrics: True to record granular metrics, at a potential performance cost.
    init(metricsSubmitter: MetricsSubmitter?, granularMetrics: Bool) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CaptureManagerError.multicamNotSuported
        }
        session = .init()
        session.automaticallyConfiguresApplicationAudioSession = false
        self.granularMetrics = granularMetrics
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        super.init()
    }

    /// Return all devices currently added to this capture session.
    /// This should be called from the main thread.
    /// - Returns Array of all added devices.
    func devices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(connections.keys)
    }

    /// Return all currently streaming devices added to this capture session.
    /// This should be called from the main thread.
    /// - Returns Array of all active added devices.
    func activeDevices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(try connections.keys.filter { try !isMuted(device: $0) })
    }

    /// Returns true if the given device has been added to this capture session.
    /// This should be called from the main thread.
    /// TODO: Remove?
    /// - Returns True if this device has been added.
    func usingInput(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return inputs[device] != nil
    }

    /// Attempt to start processing frames.
    /// This should be called from the main thread.
    func startCapturing() throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard !session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        assert(observer == nil)
        observer = notifier.addObserver(forName: .AVCaptureSessionRuntimeError,
                                        object: nil,
                                        queue: nil,
                                        using: onStartFailure)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.session.startRunning()
            if let observer = self.observer {
                self.notifier.removeObserver(observer)
            }
        }
    }

    /// Notification handler for startup failures.
    @Sendable
    private nonisolated func onStartFailure(notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            Self.logger.error("AVCaptureSession failed for unknown reason", alert: true)
            return
        }
        Self.logger.error("AVCaptureSession failure: \(error.localizedDescription)", alert: true)
    }

    /// Attempt to stop capturing frames.
    /// This should be called from the main thread.
    /// This should only be called after a successful call to startCapturing.
    func stopCapturing() throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        self.session.stopRunning()
    }

    // TODO: Make this awaitable.
    /// Toggle the mute/active state of the given device.
    /// - Parameter device The give to toggle.
    /// - Parameter toggled Callback when toggle is completed, with the now-current active state.
    /// This should be called from the main thread.
    func toggleInput(device: AVCaptureDevice, toggled: @escaping (Bool) -> Void) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = self.connections[device] else { fatalError() }
        queue.async { [weak connection] in
            guard let connection = connection else { return }
            connection.isEnabled.toggle()
            toggled(connection.isEnabled)
        }
    }

    private func setBestDeviceFormat(device: AVCaptureDevice, listener: FrameListener) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let allowableFormats = device.formats.reversed().filter { format in
            return format.isMultiCamSupported &&
                   format.formatDescription.dimensions.width == listener.codec.width &&
                   format.formatDescription.dimensions.height == listener.codec.height
        }

        guard let bestFormat = allowableFormats.first(where: { format in
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate == Float64(listener.codec.fps) }
        }) else {
            return
        }

        device.activeFormat = bestFormat

    }

    private func addCamera(listener: FrameListener) throws {
        // Device is already setup, add this delegate.
        let device = listener.device

        if var cameraFrameListeners = self.multiVideoDelegate[device] {
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            guard let maxFramerateRange = ranges.max(by: { $0.maxFrameRate > $1.maxFrameRate }) else {
                throw "No framerate set"
            }

            if maxFramerateRange.maxFrameRate < Float64(listener.codec.fps) {
                try setBestDeviceFormat(device: device, listener: listener)
            }

            cameraFrameListeners.append(listener)
            self.multiVideoDelegate[device] = cameraFrameListeners
            return
        }

        // Setup device.
        try setBestDeviceFormat(device: device, listener: listener)

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
        startTime[output] = .now
        self.multiVideoDelegate[device] = [listener]
    }

    /// Add the given frame listener, adding the requested device if not already.
    /// - Parameter listener The interested frame listener.
    /// This should be called from the main thread.
    func addInput(_ listener: FrameListener) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        Self.logger.info("Adding capture device: \(listener.device.localizedName)")

        if listener.device.deviceType == .builtInMicrophone {
            throw CaptureManagerError.noAudio
        }

        try addCamera(listener: listener)
    }

    /// Remove the given input from the capture session.
    /// - Parameter The device to remove.
    /// This should be called from the main thread.
    func removeInput(device: AVCaptureDevice) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
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

    /// Get the mute/active state for the given device.
    /// - Parameter device The device to query.
    /// - Returns True if the device is muted/disabled, false if active.
    func isMuted(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
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

    /// Data callback for AVCaptureVideoDataOutputSampleBufferDelegate.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Discard any frames prior to camera warmup.
        if let startTime = self.startTime[output] {
            guard Date.now.timeIntervalSince(startTime) > self.warmupTime else { return }
            self.startTime.removeValue(forKey: output)
        }

        if let measurement = self.measurement {
            let now: Date = .now
            let delay: Double?
            if let last = self.lastCapture {
                delay = now.timeIntervalSince(last) * 1000
            } else {
                delay = nil
            }
            self.lastCapture = now
            Task(priority: .utility) {
                await measurement.capturedFrame(delayMs: self.granularMetrics ? delay : nil,
                                                timestamp: self.granularMetrics ? now : nil)
            }
        }

        let cameraFrameListeners = getDelegate(output: output)
        for listener in cameraFrameListeners {
            listener.queue.async {
                listener.captureOutput?(output, didOutput: sampleBuffer, from: connection)
            }
        }
    }

    /// Frame drop handler for AVCaptureVideoDataOutputSampleBufferDelegate.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let cameraFrameListeners = getDelegate(output: output)
        for listener in cameraFrameListeners {
            listener.queue.async {
                listener.captureOutput?(output, didOutput: sampleBuffer, from: connection)
            }
        }
    }
}

extension UIDeviceOrientation {
    /// Return the corresponding AVCaptureVideoOrientation for this UIDeviceOrientation.
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

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

public extension AVCaptureDevice {
    /// An unsigned 64 bit probably unique identifier for a capture device.
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

/// Represents the ability to receive camera frames.
protocol FrameListener {
    /// The queue that this object will receive camera frames on.
    var queue: DispatchQueue { get }

    /// The device this listener is interested in receiving frames from.
    var device: AVCaptureDevice { get }

    /// Optionally, the configuration that the listener wishes to receive frames in from ``device``.
    /// This is a best-effort minimum value, callers MUST NOT assume the format of the received frames will match this.
    var codec: VideoCodecConfig? { get }

    /// This function will be called with video frames from the target ``device``, executed on ``queue``.
    /// - Parameter sampleBuffer: The camera frame.
    /// - Parameter timestamp: The timestamp this frame was captured at.
    func onFrame(_ sampleBuffer: CMSampleBuffer, timestamp: Date)
}

fileprivate extension FrameListener {
    func isEqual(_ other: FrameListener) -> Bool {
        self.queue == other.queue &&
            self.device == other.device &&
            self.codec == other.codec
    }
}

/// Possible errors raised by ``CaptureManager``.
enum CaptureManagerError: Error {
    /// `AVCaptureMultiCamSession` is not supported on this platform.
    case multicamNotSuported
    /// The requested operation is invalid in this state. (E.g start when started).
    case badSessionState
    /// The requested operation targeted a device is not registered.
    case missingInput(AVCaptureDevice)
    /// Failed to add the target device.
    case couldNotAdd(AVCaptureDevice)
    /// ``CaptureManager`` should not be used to manage audio devices. See ``DecimusAudioEngine``.
    case noAudio
    /// The requested operation MUST be called from the main thread, and was not.
    case mainThread
}

/// Manages local video capture.
class CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let logger = DecimusLogger(CaptureManager.self)

    /// Describe events that can happen to devices.
    enum DeviceEvent { case added; case removed }

    /// Callback of a device event.
    typealias DeviceChangeCallback = (AVCaptureDevice, DeviceEvent) -> Void

    #if os(macOS)
    private let session: AVCaptureSession
    #else
    private let session: AVCaptureMultiCamSession
    #endif
    private var inputs: [AVCaptureDevice: AVCaptureDeviceInput] = [:]
    private var outputs: [AVCaptureOutput: AVCaptureDevice] = [:]
    private var startTime: [AVCaptureOutput: Date] = [:]
    private var connections: [AVCaptureDevice: AVCaptureConnection] = [:]
    private var multiVideoDelegate: [AVCaptureDevice: [FrameListener]] = [:]
    private let queue: DispatchQueue = .init(label: "com.cisco.quicr.Decimus.CaptureManager", qos: .userInteractive)
    private let notifier: NotificationCenter = .default
    private var observer: NSObjectProtocol?
    private let measurement: MeasurementRegistration<CaptureManagerMeasurement>?
    private let granularMetrics: Bool
    private let warmupTime: TimeInterval = 0.75
    private var pressureObservations: [AVCaptureDevice: NSObjectProtocol] = [:]
    private let bootDate: Date

    /// Create a new ``CaptureManager``.
    /// - Parameter metricsSubmitter: Optionally, a submitter to collect/submit metrics through.
    /// - Parameter granularMetrics: Collect granular metrics when a submitter is present,
    /// at a potential performance penalty.
    init(metricsSubmitter: MetricsSubmitter?, granularMetrics: Bool) throws {
        #if !os(macOS)
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CaptureManagerError.multicamNotSuported
        }
        #endif
        session = .init()
        #if !os(macOS)
        session.automaticallyConfiguresApplicationAudioSession = false
        #endif
        self.granularMetrics = granularMetrics
        if let metricsSubmitter = metricsSubmitter {
            let measurement = CaptureManager.CaptureManagerMeasurement()
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.bootDate = Date.now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        super.init()
    }

    /// Get a list of all managed devices.
    /// - Throws: ``CaptureManagerError/mainThread``. Must be called on the main thread.
    func devices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(connections.keys)
    }

    /// Get the subset of ``devices()`` that are active.
    /// - Throws: ``CaptureManagerError/mainThread``. Must be called on the main thread.
    func activeDevices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(try connections.keys.filter { try !isMuted(device: $0) })
    }

    /// Is the given device is already registered to the manager?
    /// - Returns: True if managed.
    /// - Throws: ``CaptureManagerError/mainThread``. Must be called on the main thread.
    func usingInput(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return inputs[device] != nil
    }

    /// Start capturing video from all target devices.
    /// - Throws: ``CaptureManagerError/mainThread``. Must be called on the main thread.
    /// ``CaptureManagerError/badSessionState`` if already running.
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

    private func onStartFailure(notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            Self.logger.error("AVCaptureSession failed for unknown reason")
            return
        }
        Self.logger.error("AVCaptureSession failure: \(error.localizedDescription)")
    }

    /// Stop capturing media.
    /// - Throws: ``CaptureManagerError/mainThread``. Must be called on the main thread.
    /// ``CaptureManagerError/badSessionState`` if already stopped.
    func stopCapturing() throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        self.session.stopRunning()
    }

    /// Mute/unmute the target device.
    /// - Parameter device: The device to toggle mute status on.
    /// - Parameter toggled: Callback with the new current state.
    /// - Throws: ``CaptureManagerError/mainThread``. Must be called on the main thread.
    func toggleInput(device: AVCaptureDevice, toggled: @escaping (Bool) -> Void) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = self.connections[device] else { fatalError() }
        queue.async { [weak connection] in
            guard let connection = connection else { return }
            #if os(macOS)
            guard let connection = connection.output?.connections.first else { return }
            #endif
            connection.isEnabled.toggle()
            toggled(connection.isEnabled)
        }
    }

    private func setBestDeviceFormat(device: AVCaptureDevice, config: VideoCodecConfig) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let allowableFormats = device.formats.reversed().filter { format in
            var supported =
                format.formatDescription.dimensions.width == config.width &&
                format.formatDescription.dimensions.height == config.height &&
                format.supportedColorSpaces.contains(.sRGB) &&
                format.formatDescription.mediaSubType == .init(string: "420v")
            if config.codec == .hevc {
                #if !os(macOS)
                supported = supported && format.isVideoHDRSupported
                #endif
            }
            return supported
        }

        guard let bestFormat = allowableFormats.first(where: { format in
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate == Float64(config.fps) }
        }) else {
            return
        }

        self.session.beginConfiguration()
        device.activeFormat = bestFormat
        if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        self.session.commitConfiguration()
    }

    private func addCamera(listener: FrameListener) throws {
        // Device is already setup, add this delegate.
        let device = listener.device

        if var cameraFrameListeners = self.multiVideoDelegate[device] {
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            guard let maxFramerateRange = ranges.max(by: { $0.maxFrameRate > $1.maxFrameRate }) else {
                throw "No framerate set"
            }

            if let config = listener.codec {
                if maxFramerateRange.maxFrameRate < Float64(config.fps) {
                    try setBestDeviceFormat(device: device, config: config)
                }
            }

            cameraFrameListeners.append(listener)
            self.multiVideoDelegate[device] = cameraFrameListeners
            return
        }

        // Setup device.
        if let config = listener.codec {
            try setBestDeviceFormat(device: device, config: config)
        }

        // Register for pressure state notifications.
        #if !os(macOS)
        let token = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] _, _ in
            guard let self = self else { return }
            self.recordPressureState(device)
        }
        self.pressureObservations[device] = token
        #endif

        // Prepare IO.
        // TODO: Theoretically all of these may need to be reconfigured on a device format change.
        let input: AVCaptureDeviceInput = try .init(device: device)
        let output: AVCaptureVideoDataOutput = .init()
        let lossless420 = kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange
        output.videoSettings = [:]
        if output.availableVideoPixelFormatTypes.contains(where: {
            $0 == lossless420
        }) {
            output.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] = lossless420
            Self.logger.debug("[\(device.localizedName)] Using lossy compressed format")
        }
        #if !os(macOS)
        output.videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        #endif
        output.setSampleBufferDelegate(self, queue: self.queue)
        guard session.canAddInput(input),
              session.canAddOutput(output) else {
            throw CaptureManagerError.couldNotAdd(device)
        }
        let connection: AVCaptureConnection = .init(inputPorts: input.ports, output: output)

        // Apply these changes.
        session.beginConfiguration()
        #if os(macOS)
        session.addOutput(output)
        session.addInput(input)
        #else
        session.addOutputWithNoConnections(output)
        session.addInputWithNoConnections(input)
        session.addConnection(connection)
        #endif

        // Done.
        session.commitConfiguration()
        outputs[output] = device
        inputs[device] = input
        connections[device] = connection
        startTime[output] = .now
        self.multiVideoDelegate[device] = [listener]
    }

    /// Add a listener for frame callbacks, adding the target device if not already.
    /// - Parameter listener: Receiver of video frames.
    /// - Throws: ``CaptureManagerError/mainThread``. Must be called on the main thread.
    func addInput(_ listener: FrameListener) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        Self.logger.info("Adding capture device: \(listener.device.localizedName)")

        #if !os(tvOS)
        if listener.device.deviceType == .microphone {
            throw CaptureManagerError.noAudio
        }
        #endif

        try addCamera(listener: listener)
    }

    /// Remove a listener for frame callbacks,
    /// removing the target device if no other listeners targetting that device are left.
    /// - Parameter listener: Receiver of video frames.
    /// - Throws: ``CaptureManagerError/mainThread`` if called on a thread other than Main.
    /// ``CaptureManagerError/missingInput(_:)`` if the device is not already tracked.
    func removeInput(listener: FrameListener) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }

        let device = listener.device
        guard var deviceListeners = self.multiVideoDelegate[device] else {
            throw CaptureManagerError.missingInput(device)
        }

        // Remove this frame listener from the list.
        deviceListeners.removeAll {
            listener.isEqual($0)
        }

        guard deviceListeners.count == 0 else {
            // There are other listeners still, so update and stop.
            self.multiVideoDelegate[device] = deviceListeners
            return
        }

        // There are no more delegates left, we should remove the device.
        self.multiVideoDelegate.removeValue(forKey: device)
        self.pressureObservations.removeValue(forKey: device)
        let input = inputs.removeValue(forKey: device)
        assert(input != nil)
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

    /// Query the mute state of the target device.
    /// - Parameter device: The device to query.
    /// - Returns: True if currently muted.
    /// - Throws: ``CaptureManagerError/mainThread`` if called on a thread other than Main.
    /// ``CaptureManagerError/missingInput(_:)`` if the device is not already tracked.
    func isMuted(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = connections[device] else {
            throw CaptureManagerError.missingInput(device)
        }
        return !connection.isEnabled
    }

    /// Add a preview view for a device.
    /// - Parameter device: The device to add a preview for.
    /// - Parameter preview: The preview layer to hook to the device.
    func addPreview(device: AVCaptureDevice, preview: AVCaptureVideoPreviewLayer) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = connections[device] else {
            throw CaptureManagerError.missingInput(device)
        }
        let previewConnection = AVCaptureConnection(inputPort: connection.inputPorts.first!, videoPreviewLayer: preview)
        guard self.session.canAddConnection(previewConnection) else {
            throw CaptureManagerError.couldNotAdd(device)
        }
        self.session.addConnection(previewConnection)
    }

    private func getDelegate(output: AVCaptureOutput) -> [FrameListener] {
        guard let device = self.outputs[output],
              let subscribers = self.multiVideoDelegate[device] else {
            return []
        }
        return subscribers
    }

    /// `AVCaptureVideoDataOutputSampleBufferDelegate` camera frame callback.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Discard any frames prior to camera warmup.
        let now = Date.now
        if let startTime = self.startTime[output] {
            guard now.timeIntervalSince(startTime) > self.warmupTime else { return }
            self.startTime.removeValue(forKey: output)
        }

        // Convert relative timestamp into absolute.
        let absoluteTimestamp = self.bootDate.addingTimeInterval(sampleBuffer.presentationTimeStamp.seconds)

        // Metrics.
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.capturedFrame(frameTimestamp: absoluteTimestamp.timeIntervalSince1970,
                                                            metricsTimestamp: self.granularMetrics ? now : nil)
            }
        }

        // Pass on frame to listeners.
        let cameraFrameListeners = getDelegate(output: output)
        for listener in cameraFrameListeners {
            listener.queue.async {
                listener.onFrame(sampleBuffer, timestamp: absoluteTimestamp)
            }
        }
    }

    /// `AVCaptureVideoDataOutputSampleBufferDelegate` dropped frame callback.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var mode: CMAttachmentMode = 0
        let reason = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: &mode)
        Self.logger.warning("\(String(describing: reason))")
        guard let measurement = self.measurement else { return }
        let now: Date? = self.granularMetrics ? Date.now : nil
        Task(priority: .utility) {
            await measurement.measurement.droppedFrame(timestamp: now)
        }
    }

    private func recordPressureState(_ device: AVCaptureDevice) {
        #if !os(macOS)
        let pressure = device.systemPressureState
        let level: Int
        let factor: String
        switch pressure.factors {
        case .cameraTemperature:
            factor = "Camera Temperature"
        case .depthModuleTemperature:
            factor = "Depth Temperature"
        case .peakPower:
            factor = "Power"
        case .systemTemperature:
            factor = "System Temperature"
        default:
            factor = "Unknown"
        }
        switch pressure.level {
        case .nominal:
            Self.logger.debug("[\(device.localizedName)] Capture pressure nominal")
            level = 0
        case .fair:
            Self.logger.info("[\(device.localizedName)] Capture pressure fair: \(factor)")
            level = 1
        case .serious:
            Self.logger.warning("[\(device.localizedName)] Capture pressure serious: \(factor)",
                                alert: true)
            level = 2
        case .critical:
            Self.logger.warning("[\(device.localizedName)] Pressure pressure critical: \(factor)",
                                alert: true)
            level = 3
        case .shutdown:
            Self.logger.error("[\(device.localizedName)] Capture shutdown due to pressure: \(factor)")
            level = 4
        default:
            Self.logger.info("[\(device.localizedName)] Unknown pressure state")
            level = -1
        }

        // Record pressure state as a metric.
        if let measurement = measurement?.measurement {
            let now = Date.now
            Task(priority: .utility) {
                await measurement.pressureStateChanged(level: level, metricsTimestamp: now)
            }
        }
        #endif
    }
}

#if !os(tvOS) && !os(macOS)
extension UIDeviceOrientation {
    /// Get Decimus' representation of this orientation.
    var videoOrientation: DecimusVideoRotation {
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

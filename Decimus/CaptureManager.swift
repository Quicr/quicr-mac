import AVFoundation
import UIKit
import os

public extension AVCaptureDevice {
    var id: UInt64 {
        .init(truncatingIfNeeded: uniqueID.hashValue)
    }
}

protocol FrameListener {
    var queue: DispatchQueue { get }
    var device: AVCaptureDevice { get }
    var codec: VideoCodecConfig? { get }
    func onFrame(_ sampleBuffer: CMSampleBuffer, captureTime: Date)
}

fileprivate extension FrameListener {
    func isEqual(_ other: FrameListener) -> Bool {
        self.queue == other.queue &&
            self.device == other.device &&
            self.codec == other.codec
    }
}

enum CaptureManagerError: Error {
    case multicamNotSuported
    case badSessionState
    case missingInput(AVCaptureDevice)
    case couldNotAdd(AVCaptureDevice)
    case noAudio
    case mainThread
}

/// Manages local media capture.
class CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
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
    private let measurement: CaptureManagerMeasurement?
    private let metricsSubmitter: MetricsSubmitter?
    private let granularMetrics: Bool
    private let warmupTime: TimeInterval = 0.75
    private var selectedFormat: [AVCaptureDevice: AVCaptureDevice.Format] = [:]

    init(metricsSubmitter: MetricsSubmitter?, granularMetrics: Bool) throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CaptureManagerError.multicamNotSuported
        }
        session = .init()
        session.automaticallyConfiguresApplicationAudioSession = false
        self.granularMetrics = granularMetrics
        self.metricsSubmitter = metricsSubmitter
        if let metricsSubmitter = metricsSubmitter {
            let measurement = CaptureManager.CaptureManagerMeasurement()
            self.measurement = measurement
            Task(priority: .utility) {
                await metricsSubmitter.register(measurement: measurement)
            }
        } else {
            self.measurement = nil
        }
        super.init()
    }

    deinit {
        if let measurement = self.measurement,
           let metricsSubmitter = self.metricsSubmitter {
            let id = measurement.id
            Task(priority: .utility) {
                await metricsSubmitter.unregister(id: id)
            }
        }
    }

    func devices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(connections.keys)
    }

    func activeDevices() throws -> [AVCaptureDevice] {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return Array(try connections.keys.filter { try !isMuted(device: $0) })
    }

    func usingInput(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        return inputs[device] != nil
    }

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

    @Sendable
    private nonisolated func onStartFailure(notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            Self.logger.error("AVCaptureSession failed for unknown reason", alert: true)
            return
        }
        Self.logger.error("AVCaptureSession failure: \(error.localizedDescription)", alert: true)
    }

    func stopCapturing() throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard session.isRunning else {
            throw CaptureManagerError.badSessionState
        }
        self.session.stopRunning()
    }

    func toggleInput(device: AVCaptureDevice, toggled: @escaping (Bool) -> Void) throws {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = self.connections[device] else { fatalError() }
        queue.async { [weak connection] in
            guard let connection = connection else { return }
            connection.isEnabled.toggle()
            toggled(connection.isEnabled)
        }
    }

    // Rules for setting a format.
    // - The highest resolution requested will be preferred.
    // - The frame rate chosen will be the lower of the highest selected resolution's highest frame rate,
    // and the requested frame rate.
    private func setBestDeviceFormat(device: AVCaptureDevice, config: VideoCodecConfig) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Get available formats for the given resolution requirements.
        let allowableFormats = device.formats.reversed().filter { format in
            var supported = format.isMultiCamSupported &&
                format.formatDescription.dimensions.width == config.width &&
                format.formatDescription.dimensions.height == config.height &&
                format.supportedColorSpaces.contains(.sRGB)
            if config.codec == .hevc {
                supported = supported && format.isVideoHDRSupported
            }
            return supported
        }

        // Did we get a match? If not, best effort.
        guard allowableFormats.count > 0 else {
            Self.logger.debug("""
            [\(device.localizedName)] Couldn't find an exact format match for: \(config.getResolutionString()).
            Staying with \(device.activeFormat)
            """)
            return
        }

        // Is there a format that matches the required frame rate?
        let bestFormat: AVCaptureDevice.Format
        if let frameRateMatched = allowableFormats.first(where: {
            $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate == Float64(config.fps) }
        }) {
            // This matches our frame rate target.
            bestFormat = frameRateMatched
        } else {
            // Otherwise, pick the best <= fame rate.
            Self.logger.warning("[\(device.localizedName)] Camera does not support requested frame rate: \(config.fps)")
            guard let backupFormat = allowableFormats.first(where: {
                $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate <= Float64(config.fps) }
            }) else {
                Self.logger.error(
                    "[\(device.localizedName)] Couldn't select a backup format. Staying with \(device.activeFormat)")
                return
            }
            bestFormat = backupFormat
        }

        // Now that we have a format, should we switch to it?
        let shouldSwitch: Bool
        if let existingFormat = self.selectedFormat[device] {
            // Only switch to upgrades.
            let resolutionUpgrade = {
                bestFormat.formatDescription.dimensions.width >= existingFormat.formatDescription.dimensions.width &&
                    bestFormat.formatDescription.dimensions.height >= existingFormat.formatDescription.dimensions.height
            }()
            let frameRateUpgrade = {
                let newFrameRate = bestFormat.videoSupportedFrameRateRanges.reduce(into: 0) {
                    $0 = $1.maxFrameRate > $0 ? $1.maxFrameRate : $0
                }
                let existingFrameRate = existingFormat.videoSupportedFrameRateRanges.reduce(into: 0) {
                    $0 = $1.maxFrameRate > $0 ? $1.maxFrameRate : $0
                }
                return resolutionUpgrade && newFrameRate > existingFrameRate
            }()
            shouldSwitch = resolutionUpgrade || frameRateUpgrade
        } else {
            // Should always switch if we haven't before.
            shouldSwitch = true
        }

        guard shouldSwitch else {
            Self.logger.debug(
                "[\(device.localizedName)] Not switching format from \(device.activeFormat) to \(bestFormat)")
            return
        }

        // Actually switch the camera format.
        self.session.beginConfiguration()
        device.activeFormat = bestFormat
        self.selectedFormat[device] = bestFormat
        Self.logger.info(
            "[\(device.localizedName)] Setting format: \(device.activeFormat) from \(config.getResolutionString())")
        if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        self.session.commitConfiguration()
    }

    private func addCamera(listener: FrameListener) throws {
        let device = listener.device

        // Always probe to see if there's a better format.
        if let config = listener.codec {
            try setBestDeviceFormat(device: device, config: config)
        }

        // If device is already setup, just add this delegate.
        if var cameraFrameListeners = self.multiVideoDelegate[device] {
            cameraFrameListeners.append(listener)
            self.multiVideoDelegate[device] = cameraFrameListeners
            return
        }

        // Prepare IO.
        let input: AVCaptureDeviceInput = try .init(device: device)
        let output: AVCaptureVideoDataOutput = .init()
        let lossless420 = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
        output.videoSettings = [:]
        if output.availableVideoPixelFormatTypes.contains(where: {
            $0 == lossless420
        }) {
            output.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] = lossless420
        }
        output.videoSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
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
            // TODO: Theoretically we could reevaluate the format here.
            self.multiVideoDelegate[device] = deviceListeners
            return
        }

        // There are no more delegates left, we should remove the device.
        self.multiVideoDelegate.removeValue(forKey: device)
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
        self.selectedFormat.removeValue(forKey: device)
        Self.logger.info("Removing input for \(device.localizedName)")
    }

    func isMuted(device: AVCaptureDevice) throws -> Bool {
        guard Thread.isMainThread else { throw CaptureManagerError.mainThread }
        guard let connection = connections[device] else {
            throw CaptureManagerError.missingInput(device)
        }
        return !connection.isEnabled
    }

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

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Discard any frames prior to camera warmup.
        let now = Date.now
        if let startTime = self.startTime[output] {
            guard now.timeIntervalSince(startTime) > self.warmupTime else { return }
            self.startTime.removeValue(forKey: output)
        }

        // Metrics.
        if let measurement = self.measurement {
            let timestamp = sampleBuffer.presentationTimeStamp.seconds
            Task(priority: .utility) {
                await measurement.capturedFrame(frameTimestamp: timestamp,
                                                metricsTimestamp: self.granularMetrics ? now : nil)
            }
        }

        // Pass on frame to listeners.
        let cameraFrameListeners = getDelegate(output: output)
        for listener in cameraFrameListeners {
            listener.queue.async {
                listener.onFrame(sampleBuffer, captureTime: now)
            }
        }
    }

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
            await measurement.droppedFrame(timestamp: now)
        }
    }
}

#if !os(tvOS)
extension UIDeviceOrientation {
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

extension VideoCodecConfig {
    func getResolutionString() -> String {
        "\(self.width)x\(self.height)@\(self.fps)"
    }
}

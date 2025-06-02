// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

protocol AppRecorder {
    func stopCapture() async throws
}

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit

/// Records the call to a file.
class AppRecorderImpl: AppRecorder {
    enum SCKError: Error {
        case noDisplay
        case noApp

        var localizedDescription: String {
            switch self {
            case .noDisplay:
                return "No display found."
            case .noApp:
                return "This application not found."
            }
        }
    }

    private class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
        private let logger = DecimusLogger(RecordingDelegate.self)
        func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
            self.logger.info("Started")
        }
        func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
            self.logger.error("Failed: \(error.localizedDescription)")
        }
        func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            self.logger.info("Finished")
        }
    }
    private class StreamDelegate: NSObject, SCStreamOutput { }

    private let recordingDelegate = RecordingDelegate()
    private let videoDelegate = StreamDelegate()
    private let microphoneDelegate = StreamDelegate()
    private let audioDelegate = StreamDelegate()
    private let stream: SCStream
    private let logger = DecimusLogger(AppRecorderImpl.self)

    /// Create a new recorder.
    init(filename: String, display: CGDirectDisplayID) async throws {
        // Fetch available.
        let content = try await SCShareableContent.current
        guard let ourself = content.applications.filter({ app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier
        }).first else {
            throw SCKError.noApp
        }

        // Handle multiple displays.
        let selectedDisplay: SCDisplay
        if let requested = content.displays.first(where: { $0.displayID == display }) {
            selectedDisplay = requested
        } else {
            self.logger.warning("Requested display not found (\(display)), using first available.")
            guard let first = content.displays.first else {
                throw SCKError.noDisplay
            }
            selectedDisplay = first
            self.logger.warning("Using display \(first.displayID) instead.")
        }

        // Setup stream.
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.captureMicrophone = true
        config.captureResolution = .best
        self.stream = SCStream(filter: .init(display: selectedDisplay,
                                             including: [ourself],
                                             exceptingWindows: []),
                               configuration: config,
                               delegate: nil)

        // Realtime callbacks (stop log spam).
        try self.stream.addStreamOutput(self.videoDelegate,
                                        type: .screen,
                                        sampleHandlerQueue: nil)
        try self.stream.addStreamOutput(self.audioDelegate,
                                        type: .audio,
                                        sampleHandlerQueue: nil)
        try self.stream.addStreamOutput(self.microphoneDelegate,
                                        type: .microphone,
                                        sampleHandlerQueue: nil)

        // Recording configuration.
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputFileType = .mov
        recordingConfig.outputURL = .downloadsDirectory.appendingPathComponent(filename,
                                                                               conformingTo: .quickTimeMovie)

        let recording = SCRecordingOutput(configuration: recordingConfig,
                                          delegate: self.recordingDelegate)
        try self.stream.addRecordingOutput(recording)

        // Go.
        try await self.stream.startCapture()
    }

    /// Stop the recording.
    func stopCapture() async throws {
        try await self.stream.stopCapture()
    }
}
#endif

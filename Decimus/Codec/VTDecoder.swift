// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import VideoToolbox
import Synchronization

/// Provides hardware accelerated decoding.
final class VTDecoder: Sendable {
    typealias DecodedFrameCallback = @Sendable (CMSampleBuffer) -> Void
    private let logger = DecimusLogger(VTDecoder.self)

    // Members.
    private let session: Mutex<VTDecompressionSession?> = .init(nil)
    private let callback: DecodedFrameCallback

    /// Stored codec config. Can be updated.
    private let config: VideoCodecConfig

    init(config: VideoCodecConfig, callback: @escaping DecodedFrameCallback) {
        self.config = config
        self.callback = callback
    }

    deinit {
        self.session.withLock { session in
            guard let session else { return }
            self.close(session)
        }
    }

    private func close(_ session: VTDecompressionSession) {
        let flush = VTDecompressionSessionWaitForAsynchronousFrames(session)
        if flush != .zero {
            self.logger.warning("VTDecoder failed to flush frames: \(flush)", alert: true)
        }
        VTDecompressionSessionInvalidate(session)
    }

    /// Write a new frame to the decoder.
    func write(_ sample: CMSampleBuffer) throws {
        guard let format = sample.formatDescription else {
            throw "Sample missing format"
        }

        var retry = false
        try self.session.withLock { locked in
            // Make the decoder if not already.
            let session: VTDecompressionSession
            if let locked {
                session = locked
            } else {
                session = try self.makeDecoder(format: format)
                locked = session
            }

            // Pass sample to decoder.
            var inputFlags: VTDecodeFrameFlags = .init()
            inputFlags.insert(._EnableAsynchronousDecompression)
            var outputFlags: VTDecodeInfoFlags = .init()
            let decodeError = VTDecompressionSessionDecodeFrame(session,
                                                                sampleBuffer: sample,
                                                                flags: inputFlags,
                                                                infoFlagsOut: &outputFlags,
                                                                outputHandler: self.frameCallback)

            switch decodeError {
            case kVTFormatDescriptionChangeNotSupportedErr:
                // We need to recreate the decoder because of a format change.
                self.logger.info("Recreating due to format change")
                self.close(session)
                locked = try self.makeDecoder(format: format)
                retry = true
            case .zero:
                break
            default:
                throw OSStatusError(error: decodeError, message: "Failed to decode frame")
            }
        }
        if retry {
            try self.write(sample)
        }
    }

    /// Makes a new decoder for the given format.
    private func makeDecoder(format: CMFormatDescription) throws -> VTDecompressionSession {
        // Output format properties.
        var outputFormat: [String: Any] = [:]
        let targetFormat: OSType?
        switch format.mediaSubType {
        case .h264:
            targetFormat = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
        default:
            targetFormat = nil
        }

        if let targetFormat = targetFormat {
            if CVIsCompressedPixelFormatAvailable(targetFormat) {
                outputFormat[kCVPixelBufferPixelFormatTypeKey as String] = targetFormat
            }
        }

        // Create the session.
        var session: VTDecompressionSession?
        let error = VTDecompressionSessionCreate(allocator: nil,
                                                 formatDescription: format,
                                                 decoderSpecification: nil,
                                                 imageBufferAttributes: outputFormat as CFDictionary,
                                                 outputCallback: nil,
                                                 decompressionSessionOut: &session)
        guard error == .zero else {
            throw OSStatusError(error: error, message: "Failed to create VTDecompressionSession")
        }

        // Configure for realtime.
        VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        return session!
    }

    func frameCallback(status: OSStatus,
                       flags: VTDecodeInfoFlags,
                       image: CVImageBuffer?,
                       presentation: CMTime,
                       duration: CMTime) {
        // Check status code.
        guard status == .zero else { self.logger.error("Bad decode: \(status)"); return }

        // Fire callback with the decoded image.
        guard let image = image else { self.logger.error("Missing image"); return }
        do {
            let created: CMVideoFormatDescription = try .init(imageBuffer: image)
            let sample: CMSampleBuffer = try .init(imageBuffer: image,
                                                   formatDescription: created,
                                                   sampleTiming: .init(duration: duration,
                                                                       presentationTimeStamp: presentation,
                                                                       decodeTimeStamp: .invalid))
            callback(sample)
        } catch {
            self.logger.error("Couldn't create CMSampleBuffer: \(error)")
        }
    }
}

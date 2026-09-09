// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private let frameRate: Int32 = 30
private let frameCount = 150

private struct QualitySpec {
    let label: String
    let width: Int
    let height: Int
    let bitrate: Int
}

private let qualities = [
    QualitySpec(label: "1080p", width: 1920, height: 1080, bitrate: 4_000_000),
    QualitySpec(label: "720p", width: 1280, height: 720, bitrate: 2_000_000),
    QualitySpec(label: "360p", width: 640, height: 360, bitrate: 800_000)
]

private struct GeneratorError: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
}

private final class EncodedFrame {
    let index: Int
    let sample: CMSampleBuffer
    let isIDR: Bool

    init(index: Int, sample: CMSampleBuffer, isIDR: Bool) {
        self.index = index
        self.sample = sample
        self.isIDR = isIDR
    }
}

private final class EncoderState {
    let lock = NSLock()
    var frames: [EncodedFrame] = []
    var error: Error?
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func makePixelBuffer(frame index: Int, quality: QualitySpec) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                     quality.width,
                                     quality.height,
                                     kCVPixelFormatType_32BGRA,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                     &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw GeneratorError(message: "Could not create \(quality.label) pixel buffer: \(status)")
    }

    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw GeneratorError(message: "Could not lock \(quality.label) pixel buffer: \(lockStatus)")
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let barWidth = quality.width / 8
    let squareWidth = max(24, quality.width / 13)
    let colours: [(UInt8, UInt8, UInt8)] = [
        (255, 32, 32), (32, 255, 32), (32, 32, 255), (255, 255, 32),
        (255, 32, 255), (32, 255, 255), (255, 160, 32), (224, 224, 224)
    ]
    let squareX = -squareWidth + (index * (quality.width + squareWidth) / (frameCount - 1))
    let squareTop = quality.height / 2 - squareWidth / 2
    let squareBottom = squareTop + squareWidth

    for y in 0..<quality.height {
        let row = baseAddress.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<quality.width {
            let colour = colours[min(x / barWidth, colours.count - 1)]
            let square = x >= squareX && x < squareX + squareWidth && y >= squareTop && y < squareBottom
            let offset = x * 4
            row[offset] = square ? 255 : colour.2
            row[offset + 1] = square ? 255 : colour.1
            row[offset + 2] = square ? 255 : colour.0
            row[offset + 3] = 255
        }
    }
    return pixelBuffer
}

private func sampleBytes(_ sample: CMSampleBuffer) throws -> Data {
    guard let block = sample.dataBuffer else {
        throw GeneratorError(message: "Encoded sample has no data buffer")
    }
    var data = Data(count: block.dataLength)
    try data.withUnsafeMutableBytes { bytes in
        try block.copyDataBytes(to: bytes)
    }
    return data
}

private func parameterSet(_ format: CMFormatDescription, index: Int) throws -> Data {
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    var count = 0
    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                                                                    parameterSetIndex: index,
                                                                    parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size,
                                                                    parameterSetCountOut: &count,
                                                                    nalUnitHeaderLengthOut: nil)
    guard status == noErr, let pointer, size > 0 else {
        throw GeneratorError(message: "Missing H.264 parameter set \(index): \(status)")
    }
    return Data(bytes: pointer, count: size)
}

private func encode(_ quality: QualitySpec) throws -> [EncodedFrame] {
    let state = EncoderState()
    var compression: VTCompressionSession?
    let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon else { return }
        let state = Unmanaged<EncoderState>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr, let sampleBuffer else {
            state.lock.withLock {
                state.error = GeneratorError(message: "VideoToolbox encoding failed: \(status)")
            }
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let keyframe = (attachments as? [[String: Any]])?.first?[
            kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        let index = Int(sampleBuffer.presentationTimeStamp.value)
        state.lock.withLock {
            state.frames.append(.init(index: index, sample: sampleBuffer, isIDR: keyframe))
        }
    }

    guard VTCompressionSessionCreate(allocator: nil,
                                     width: Int32(quality.width),
                                     height: Int32(quality.height),
                                     codecType: kCMVideoCodecType_H264,
                                     encoderSpecification: nil,
                                     imageBufferAttributes: nil,
                                     compressedDataAllocator: nil,
                                     outputCallback: callback,
                                     refcon: Unmanaged.passUnretained(state).toOpaque(),
                                     compressionSessionOut: &compression) == noErr,
          let compression else {
        throw GeneratorError(message: "Could not create \(quality.label) H.264 compression session")
    }
    defer { VTCompressionSessionInvalidate(compression) }

    func setProperty(_ key: CFString, _ value: CFTypeRef) throws {
        let status = VTSessionSetProperty(compression, key: key, value: value)
        guard status == noErr else {
            throw GeneratorError(message: "Could not set VideoToolbox property \(key): \(status)")
        }
    }

    try setProperty(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
    try setProperty(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
    try setProperty(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    try setProperty(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
    try setProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: frameCount))
    try setProperty(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 5.0))
    try setProperty(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: quality.bitrate))

    VTCompressionSessionPrepareToEncodeFrames(compression)
    for index in 0..<frameCount {
        let pixelBuffer = try makePixelBuffer(frame: index, quality: quality)
        let properties: CFDictionary? = index == 0 ?
            [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(compression,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: CMTime(value: CMTimeValue(index),
                                                                                   timescale: frameRate),
                                                     duration: CMTime(value: 1, timescale: frameRate),
                                                     frameProperties: properties,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: nil)
        guard status == noErr else {
            throw GeneratorError(message: "Could not encode \(quality.label) frame \(index): \(status)")
        }
    }
    guard VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid) == noErr else {
        throw GeneratorError(message: "Could not complete \(quality.label) VideoToolbox frames")
    }

    let result = state.lock.withLock { (state.frames.sorted { $0.index < $1.index }, state.error) }
    if let error = result.1 { throw error }
    let frames = result.0
    guard frames.count == frameCount,
          frames.first?.index == 0,
          frames.last?.index == frameCount - 1,
          frames.filter(\.isIDR).count == 1,
          frames.first?.isIDR == true else {
        throw GeneratorError(message: "Unexpected \(quality.label) encoded frame sequence")
    }
    return frames
}

private func appendLengthPrefixed(_ nalu: Data, to output: inout Data) {
    appendUInt32(UInt32(nalu.count), to: &output)
    output.append(nalu)
}

private func appendUInt16(_ value: UInt16, to output: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
}

private func appendUInt32(_ value: UInt32, to output: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
}

private func append(_ frames: [EncodedFrame], quality: QualitySpec, index: UInt8,
                    to output: inout Data) throws {
    output.append(index)
    appendUInt16(UInt16(frameRate), to: &output)
    appendUInt16(UInt16(quality.width), to: &output)
    appendUInt16(UInt16(quality.height), to: &output)
    appendUInt16(UInt16(frames.count), to: &output)
    guard let format = frames[0].sample.formatDescription else {
        throw GeneratorError(message: "Missing \(quality.label) encoded format")
    }
    for frame in frames {
        var payload = Data()
        if frame.index == 0 {
            appendLengthPrefixed(try parameterSet(format, index: 0), to: &payload)
            appendLengthPrefixed(try parameterSet(format, index: 1), to: &payload)
        }
        payload.append(try sampleBytes(frame.sample))
        output.append(frame.isIDR ? 1 : 0)
        appendUInt32(UInt32(payload.count), to: &output)
        output.append(payload)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fail("usage: generate_topn_h264_fixture <output>") }
let outputURL = URL(fileURLWithPath: arguments[1])

do {
    var output = Data([0x51, 0x54, 0x48, 0x31])
    appendUInt16(2, to: &output)
    appendUInt16(UInt16(qualities.count), to: &output)
    for (index, quality) in qualities.enumerated() {
        let frames = try encode(quality)
        try append(frames, quality: quality, index: UInt8(index), to: &output)
        print("quality=\(quality.label), dimensions=\(quality.width)x\(quality.height), " +
              "frames=\(frames.count), IDRs=\(frames.filter(\.isIDR).count)")
    }
    try output.write(to: outputURL, options: .atomic)
} catch {
    fail(String(describing: error))
}

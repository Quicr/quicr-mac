// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private let width = 320
private let height = 180
private let frameRate: Int32 = 30
private let frameCount = 150
private let squareWidth = 24

private struct GeneratorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

private func makePixelBuffer(frame index: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                     width,
                                     height,
                                     kCVPixelFormatType_32BGRA,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                     &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw GeneratorError(message: "Could not create pixel buffer: \(status)")
    }

    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw GeneratorError(message: "Could not lock pixel buffer: \(lockStatus)")
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let barWidth = width / 8
    let colours: [(UInt8, UInt8, UInt8)] = [
        (255, 32, 32), (32, 255, 32), (32, 32, 255), (255, 255, 32),
        (255, 32, 255), (32, 255, 255), (255, 160, 32), (224, 224, 224)
    ]
    let squareX = -squareWidth + (index * (width + squareWidth) / (frameCount - 1))

    for y in 0..<height {
        let row = baseAddress.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let colour = colours[min(x / barWidth, colours.count - 1)]
            let square = x >= squareX && x < squareX + squareWidth && y >= 78 && y < 102
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

private func appendLengthPrefixed(_ nalu: Data, to output: inout Data) {
    var length = UInt32(nalu.count).bigEndian
    withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
    output.append(nalu)
}

private func writeUInt16(_ value: UInt16, to output: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
}

private func writeUInt32(_ value: UInt32, to output: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fail("usage: generate_topn_h264_fixture <output>") }
let outputURL = URL(fileURLWithPath: arguments[1])
private let state = EncoderState()
var compression: VTCompressionSession?

let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
    guard let refcon else { return }
    let state = Unmanaged<EncoderState>.fromOpaque(refcon).takeUnretainedValue()
    guard status == noErr, let sampleBuffer else {
        state.lock.lock()
        state.error = GeneratorError(message: "VideoToolbox encoding failed: \(status)")
        state.lock.unlock()
        return
    }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
    let keyframe = (attachments as? [[String: Any]])?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
    let index = Int(sampleBuffer.presentationTimeStamp.value)
    state.lock.lock()
    state.frames.append(.init(index: index, sample: sampleBuffer, isIDR: keyframe))
    state.lock.unlock()
}

guard VTCompressionSessionCreate(allocator: nil,
                                 width: Int32(width),
                                 height: Int32(height),
                                 codecType: kCMVideoCodecType_H264,
                                 encoderSpecification: nil,
                                 imageBufferAttributes: nil,
                                 compressedDataAllocator: nil,
                                 outputCallback: callback,
                                 refcon: Unmanaged.passUnretained(state).toOpaque(),
                                 compressionSessionOut: &compression) == noErr,
      let compression else {
    fail("could not create H.264 compression session")
}

func setProperty(_ key: CFString, _ value: CFTypeRef) throws {
    let status = VTSessionSetProperty(compression, key: key, value: value)
    guard status == noErr else {
        throw GeneratorError(message: "Could not set VideoToolbox property \(key): \(status)")
    }
}

do {
    try setProperty(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
    try setProperty(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
    try setProperty(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
    try setProperty(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
    try setProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: frameCount))
    try setProperty(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 5.0))
    try setProperty(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 400_000))

    VTCompressionSessionPrepareToEncodeFrames(compression)
    for index in 0..<frameCount {
        let pixelBuffer = try makePixelBuffer(frame: index)
        var flags: VTEncodeInfoFlags = []
        var properties: CFDictionary?
        if index == 0 {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }
        let status = VTCompressionSessionEncodeFrame(compression,
                                                     imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: CMTime(value: CMTimeValue(index),
                                                                                   timescale: frameRate),
                                                     duration: CMTime(value: 1, timescale: frameRate),
                                                     frameProperties: properties,
                                                     sourceFrameRefcon: nil,
                                                     infoFlagsOut: &flags)
        guard status == noErr else {
            throw GeneratorError(message: "Could not encode frame \(index): \(status)")
        }
    }
    guard VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid) == noErr else {
        throw GeneratorError(message: "Could not complete VideoToolbox frames")
    }
    state.lock.lock()
    let frames = state.frames.sorted { $0.index < $1.index }
    let error = state.error
    state.lock.unlock()
    if let error { throw error }
    guard frames.count == frameCount,
          frames.first?.index == 0,
          frames.last?.index == frameCount - 1,
          frames.filter(\.isIDR).count == 1,
          frames.first?.isIDR == true else {
        throw GeneratorError(message: "Unexpected encoded frame sequence")
    }

    var output = Data([0x51, 0x54, 0x48, 0x31])
    writeUInt16(1, to: &output)
    writeUInt16(UInt16(frameRate), to: &output)
    writeUInt16(UInt16(width), to: &output)
    writeUInt16(UInt16(height), to: &output)
    writeUInt16(UInt16(frameCount), to: &output)

    guard let format = frames[0].sample.formatDescription else {
        throw GeneratorError(message: "Missing encoded format")
    }
    for frame in frames {
        var payload = Data()
        if frame.index == 0 {
            appendLengthPrefixed(try parameterSet(format, index: 0), to: &payload)
            appendLengthPrefixed(try parameterSet(format, index: 1), to: &payload)
        }
        payload.append(try sampleBytes(frame.sample))
        output.append(frame.isIDR ? 1 : 0)
        writeUInt32(UInt32(payload.count), to: &output)
        output.append(payload)
    }
    try output.write(to: outputURL, options: .atomic)
    print("fps=\(frameRate), dimensions=\(width)x\(height), frames=\(frames.count), IDRs=\(frames.filter(\.isIDR).count)")
} catch {
    fail(String(describing: error))
}

VTCompressionSessionInvalidate(compression)

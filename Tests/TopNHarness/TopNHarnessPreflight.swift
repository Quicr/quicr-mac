// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import QuicR

enum TopNHarnessPreflight {
    static func validateFixture(_ fixture: TopNH264Fixture) async throws {
        let decoder = VTDecoder(config: .init(codec: .h264,
                                              bitrate: 400_000,
                                              fps: fixture.fps,
                                              width: Int32(fixture.width),
                                              height: Int32(fixture.height),
                                              bitrateType: .average),
                                decodeBufferSize: fixture.accessUnits.count)
        let observation = DecoderObservation(expectedFrameCount: fixture.accessUnits.count)
        let outputTask = Task {
            for await sample in decoder.decoded {
                await observation.record(sample)
            }
        }
        defer { outputTask.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var format: CMFormatDescription?
                let utilities = H264Utilities()
                for accessUnit in fixture.accessUnits {
                    guard let buffers = try utilities.depacketize(accessUnit.payload,
                                                                  format: &format,
                                                                  copy: true,
                                                                  seiCallback: { _ in }) else {
                        throw TopNH264FixtureError.invalid("frame \(accessUnit.index) has no depacketized samples")
                    }
                    guard let format else {
                        throw TopNH264FixtureError.invalid("frame \(accessUnit.index) has no format description")
                    }
                    let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                                    presentationTimeStamp: CMTime(value: CMTimeValue(accessUnit.index),
                                                                                  timescale: 30),
                                                    decodeTimeStamp: .invalid)
                    for buffer in buffers {
                        let sample = try CMSampleBuffer(dataBuffer: buffer,
                                                        formatDescription: format,
                                                        numSamples: 1,
                                                        sampleTimings: [timing],
                                                        sampleSizes: [buffer.dataLength])
                        try decoder.write(sample)
                    }
                }
                while await !observation.complete {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw TopNH264FixtureError.invalid("H.264 decode preflight timed out")
            }
            try await group.next()
            group.cancelAll()
        }
        try await observation.validateForwardMotion(frameCount: fixture.accessUnits.count)
    }
}

private actor DecoderObservation {
    private struct FrameMotion {
        let index: Int
        let squareLeftEdge: Int?
    }

    private let expectedFrameCount: Int
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var frames: [FrameMotion] = []

    init(expectedFrameCount: Int) {
        self.expectedFrameCount = expectedFrameCount
    }

    var complete: Bool { self.frames.count == self.expectedFrameCount }

    func record(_ sample: CMSampleBuffer) {
        guard let imageBuffer = sample.imageBuffer else { return }
        let index = Int(sample.presentationTimeStamp.value)
        self.frames.append(.init(index: index,
                                 squareLeftEdge: self.squareLeftEdge(in: imageBuffer)))
    }

    func validateForwardMotion(frameCount: Int) throws {
        let ordered = self.frames.sorted { $0.index < $1.index }
        guard ordered.count == frameCount,
              ordered.first?.index == 0,
              ordered.last?.index == frameCount - 1 else {
            throw TopNH264FixtureError.invalid("motion check did not receive every decoded frame")
        }
        let visible = ordered.compactMap { frame in
            frame.squareLeftEdge.map { (index: frame.index, x: $0) }
        }
        guard visible.count > frameCount / 2 else {
            throw TopNH264FixtureError.invalid("motion check could not detect the white square")
        }
        for (previous, current) in zip(visible, visible.dropFirst()) where current.x < previous.x {
            throw TopNH264FixtureError.invalid(
                "square moved backwards from x=\(previous.x) at frame \(previous.index) " +
                    "to x=\(current.x) at frame \(current.index)")
        }
        guard ordered.dropFirst().dropLast().allSatisfy({ $0.squareLeftEdge != nil }) else {
            throw TopNH264FixtureError.invalid("square disappeared within the fixture")
        }
    }

    private func squareLeftEdge(in imageBuffer: CVPixelBuffer) -> Int? {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            self.context.render(CIImage(cvPixelBuffer: imageBuffer),
                                toBitmap: base,
                                rowBytes: width * 4,
                                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                format: .RGBA8,
                                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        var leftEdge: Int?
        for y in 70..<110 {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard pixels[offset] > 245,
                      pixels[offset + 1] > 245,
                      pixels[offset + 2] > 245 else { continue }
                leftEdge = min(leftEdge ?? x, x)
            }
        }
        return leftEdge
    }
}

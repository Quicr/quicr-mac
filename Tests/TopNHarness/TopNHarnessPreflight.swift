// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
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
        let observation = DecoderObservation()
        let outputTask = Task {
            for await sample in decoder.decoded {
                await observation.record(presentation: sample.presentationTimeStamp)
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
    }
}

private actor DecoderObservation {
    private var sawFirst = false
    private var sawLast = false

    var complete: Bool { sawFirst && sawLast }

    func record(presentation: CMTime) {
        sawFirst = sawFirst || presentation == .zero
        sawLast = sawLast || presentation >= CMTime(value: 149, timescale: 30)
    }
}

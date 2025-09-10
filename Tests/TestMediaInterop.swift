// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
import Testing
@testable import QuicR

extension VideoMetadata: @retroactive Equatable {
    public static func == (lhs: VideoMetadata, rhs: VideoMetadata) -> Bool {
        lhs.seqId == rhs.seqId &&
            lhs.ptsTimestamp == rhs.ptsTimestamp &&
            lhs.dtsTimestamp == rhs.dtsTimestamp &&
            lhs.timebase == rhs.timebase &&
            lhs.duration == rhs.duration &&
            lhs.wallClock == rhs.wallClock
    }
}

@Test("Media Interop Roundtrip")
func mediaInteropRoundtrip() throws {
    let timescale: CMTimeScale = 5678
    let pts = CMTime(value: 1234, timescale: timescale)
    let dts = CMTime(value: 5678, timescale: timescale)
    let duration = CMTime(value: 9012, timescale: timescale)

    let sample = try CMSampleBuffer(dataBuffer: nil,
                                    formatDescription: nil,
                                    numSamples: 1,
                                    sampleTimings: [
                                        .init(duration: duration,
                                              presentationTimeStamp: pts,
                                              decodeTimeStamp: dts)
                                    ],
                                    sampleSizes: [0])
    let sequence: UInt64 = 3456
    let now = Date.now
    let metadata = try VideoMetadata(sample: sample, sequence: sequence, date: now)
    let encoded = try metadata.toWireFormat()
    let decoded = try VideoMetadata(encoded)
    #expect(metadata == decoded)
}

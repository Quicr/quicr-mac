// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFoundation

/// A video frame and all related appliaction metadata as used in Decimus.
class DecimusVideoFrame {
    /// Video data samples and attachments (typically one).
    let samples: [CMSampleBuffer]
    /// The MoQ group ID for this frame.
    let groupId: UInt64
    /// The MoQ object ID for this frame.
    let objectId: UInt64
    /// The sequence number for this frame.
    let sequenceNumber: UInt64?
    /// If present, the expected FPS (1/duration) of this frame's stream.
    let fps: UInt8?
    /// If present, the orientation of this video frame.
    let orientation: DecimusVideoRotation?
    /// If present and true, this frame is vertically mirrored.
    let verticalMirror: Bool?

    /// Create a new video frame from its parts.
    init(samples: [CMSampleBuffer],
         groupId: UInt64,
         objectId: UInt64,
         sequenceNumber: UInt64?,
         fps: UInt8?,
         orientation: DecimusVideoRotation?,
         verticalMirror: Bool?) {
        self.samples = samples
        self.groupId = groupId
        self.objectId = objectId
        self.sequenceNumber = sequenceNumber
        self.fps = fps
        self.orientation = orientation
        self.verticalMirror = verticalMirror
    }

    /// Create a video frame by deep copying the provided frame and its data.
    /// - Parameter copy: The frame to deep copy.
    /// - Throws: No data, or failure to create destination memory blocks.
    init(copy: DecimusVideoFrame) throws {
        // Deep copy all sample data blocks.
        var samples: [CMSampleBuffer] = []
        for sample in copy.samples {
            guard let originalBuffer = sample.dataBuffer else { throw "Missing data buffer" }
            let copied: UnsafeMutableRawBufferPointer = .allocate(byteCount: originalBuffer.dataLength,
                                                                  alignment: MemoryLayout<UInt8>.alignment)
            try originalBuffer.copyDataBytes(to: copied)
            let newBuffer = try CMBlockBuffer(buffer: copied) { buffer, _ in
                buffer.deallocate()
            }
            let newSample = try CMSampleBuffer(dataBuffer: newBuffer,
                                               formatDescription: sample.formatDescription,
                                               numSamples: sample.numSamples,
                                               sampleTimings: sample.sampleTimingInfos(),
                                               sampleSizes: sample.sampleSizes())
            samples.append(newSample)
        }

        // Set all other properties.
        self.samples = samples
        self.groupId = copy.groupId
        self.objectId = copy.objectId
        self.sequenceNumber = copy.sequenceNumber
        self.fps = copy.fps
        self.orientation = copy.orientation
        self.verticalMirror = copy.verticalMirror
    }
}

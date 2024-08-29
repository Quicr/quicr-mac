import AVFoundation

class DecimusVideoFrame {
    let samples: [CMSampleBuffer]
    let groupId: UInt64
    let objectId: UInt64
    let sequenceNumber: UInt64?
    let fps: UInt8?
    let orientation: DecimusVideoRotation?
    let verticalMirror: Bool?

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

    /// Create a video frame from a deep copy of the provided frame and its data.
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

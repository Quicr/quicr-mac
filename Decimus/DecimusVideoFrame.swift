import AVFoundation

class DecimusVideoFrame {
    let samples: [CMSampleBuffer]
    let groupId: UInt32
    let objectId: UInt16
    let sequenceNumber: UInt64?
    let fps: UInt8?
    let orientation: DecimusVideoRotation?
    let verticalMirror: Bool?
    
    init(samples: [CMSampleBuffer],
         groupId: UInt32,
         objectId: UInt16,
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
}

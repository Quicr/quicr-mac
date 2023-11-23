import CoreMedia
import Foundation
import AVFoundation

enum VideoFrameError: Error {
    case missingSample
    case missingAttachments
}

struct VideoFrame {
    let samples: [CMSampleBuffer]
    let groupId: UInt32
    let objectId: UInt16
    let sequenceNumber: UInt64
    let timestamp: TimeInterval
    let orientation: AVCaptureVideoOrientation?
    let verticalMirror: Bool?
    let fps: UInt8
    
    init(samples: [CMSampleBuffer]) throws {
        self.samples = samples
        guard let first = self.samples.first else {
            throw VideoFrameError.missingSample
        }
        guard let groupId = first.getGroupId(),
              let objectId = first.getObjectId(),
              let sequenceNumber = first.getSequenceNumber(),
              let fps = first.getFPS() else {
            throw VideoFrameError.missingAttachments
        }
        self.groupId = groupId
        self.objectId = objectId
        self.sequenceNumber = sequenceNumber
        self.fps = fps
        self.timestamp = first.presentationTimeStamp.seconds
        self.orientation = first.getOrientation()
        self.verticalMirror = first.getVerticalMirror()

        // Clear custom attachments.
        for sample in self.samples {
            let array = CMSampleBufferGetSampleAttachmentsArray(sample,
                                                                createIfNecessary: false)
            if let array = array,
               let first = (array as NSArray).firstObject {
                let dict = first as! CFMutableDictionary
                let nsDict = dict as NSMutableDictionary
                nsDict.removeObjects(forKeys: [CMSampleBuffer.fpsKey,
                                               CMSampleBuffer.groupIdKey,
                                               CMSampleBuffer.objectIdKey,
                                               CMSampleBuffer.sequenceNumberKey,
                                               CMSampleBuffer.orientationKey,
                                               CMSampleBuffer.verticalMirrorKey])
            }
        }
    }
}

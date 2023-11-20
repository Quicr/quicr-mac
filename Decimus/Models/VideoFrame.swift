import CoreMedia
import Foundation
import AVFoundation

struct VideoFrame {
    let samples: [CMSampleBuffer]
}

extension VideoFrame {
    
    func getGroupId() -> UInt32 {
        return self.samples.first!.getGroupId()
    }
    
    func getObjectId() -> UInt16 {
        return self.samples.first!.getObjectId()
    }
    
    func getSeq() -> UInt64 {
        return self.samples.first!.getSequenceNumber()
    }
    
    func getTimestampInSeconds() -> Double {
        return self.samples.first!.presentationTimeStamp.seconds
    }
    
    func getOrientation() -> AVCaptureVideoOrientation? {
        return self.samples.first!.getOrienation()
    }
    
    func getVerticalMirror() -> Bool? {
        return self.samples.first!.getVerticalMirror()
    }
    
    func getFPS() -> UInt8 {
        return self.samples.first!.getFPS()
    }
    
}

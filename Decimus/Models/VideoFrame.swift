import CoreMedia
import Foundation

struct VideoFrame {
    let groupId: UInt32
    let objectId: UInt16
    let samples: [CMSampleBuffer]
}

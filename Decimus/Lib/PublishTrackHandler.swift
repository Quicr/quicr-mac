//enum TrackMode {}
//
//struct ObjectHeaders {
//    let groupId: UInt64
//    let objectId: UInt64
//    let payloadLength: UInt64
//    let priority: UInt8?
//    let ttl: UInt16?
//}
//
//protocol PublishTrackHandlerCallbacks {
//    func statusChanged(status: PublishTrackHandlerStatus)
//    func metricsSampled()
//}
//
//enum PublishTrackHandlerStatus {
//    case ok
//}
//
//class QPublishTrackHandler: NSObject {
//    func setCallbacks(callbacks: PublishTrackHandlerCallbacks) {
//
//    }
//
//    func setDefaultPriority() {
//
//    }
//
//    func setDefaultTtl() {
//
//    }
//
//    func getStatus() -> PublishTrackHandlerStatus {
//        .ok
//    }
//
//    func publishObject(headers: ObjectHeaders, data: UnsafeRawBufferPointer) -> PublishObjectStatus {
//        return .ok
//    }
//}
//
//enum PublishObjectStatus { case ok }
//
//protocol PublishTrackHandler: QPublishTrackHandler, PublishTrackHandlerCallbacks {
//}

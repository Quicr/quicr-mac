import AVFoundation
import CoreMedia
import SwiftUI

// swiftlint:disable identifier_name
enum SubscriptionError: Int32 {
    case None = 0
    case NoDecoder
}
// swiftlint:enable identifier_name

protocol Subscription: QSubscriptionDelegateObjC {
    var sourceId: SourceIDType {get}
    func prepare(_ sourceID: SourceIDType!, label: String!, profileSet: QClientProfileSet) -> Int32
    func update(_ sourceId: SourceIDType!, label: String!, profileSet: QClientProfileSet) -> Int32
    func subscribedObject(_ name: String!, data: Data!, groupId: UInt32, objectId: UInt16) -> Int32

    func log(_ message: String)
}

extension Subscription {
    func log(_ message: String) {
        print("[\(String(describing: type(of: self)))] (\(sourceId)) \(message)")
    }
}

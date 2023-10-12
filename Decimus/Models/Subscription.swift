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
    var namespace: QuicrNamespace {get}

    func prepare(_ label: String!, qualityProfile: String!, reliable: UnsafeMutablePointer<Bool>!) -> Int32
    func update(_ label: String!, qualityProfile: String!) -> Int32
    func subscribedObject(_ data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32
}

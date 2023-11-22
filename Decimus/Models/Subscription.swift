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

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 profileSet: QClientProfileSet!,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32

    func update(_ sourceId: String!,
                label: String!,
                profileSet: QClientProfileSet!) -> Int32

    func subscribedObject(_ name: String!, data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32
}

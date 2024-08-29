import Foundation

typealias QuicrNamespace = String
typealias SourceIDType = String

/// Protocol type mappings
enum ProtocolType: UInt8, CaseIterable, Codable, Identifiable, Comparable {
    static func < (lhs: ProtocolType, rhs: ProtocolType) -> Bool {
        return lhs.id < rhs.id
    }

    case UDP = 0
    case QUIC = 1
    var id: UInt8 { rawValue }
}

extension QPublishObjectStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .internalError:
            "internalError"
        case .noPreviousObject:
            "noPreviousObject"
        case .noSubscribers:
            "noSubscribers"
        case .notAnnounced:
            "notAnnounced"
        case .notAuthorized:
            "notAuthorized"
        case .objectContinuationDataNeeded:
            "objectContinuationDataNeeded"
        case .objectDataComplete:
            "objectDataComplete"
        case .objectDataIncomplete:
            "objectDataIncomplete"
        case .objectDataTooLarge:
            "objectDataTooLarge"
        case .objectPayloadLengthExceeded:
            "objectPayloadLengthExceeded"
        case .ok:
            "ok"
        case .previousObjectNotCompleteMustStartNewGroup:
            "previousObjectNotCompleteMustStartNewGroup"
        case .previousObjectNotCompleteMustStartNewTrack:
            "previousObjectNotCompleteMustStartNewTrack"
        case .previousObjectTruncated:
            "previousObjectTruncated"
        @unknown default:
            "unknown default"
        }
    }
}

extension QPublishTrackHandlerStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ok:
            "ok"
        case .announceNotAuthorized:
            "announceNotAuthorized"
        case .noSubscribers:
            "noSubscribers"
        case .notAnnounced:
            "notAnnounced"
        case .notConnected:
            "notConnected"
        case .pendingAnnounceResponse:
            "pendingAnnounceResponse"
        case .sendingUnannounce:
            "sendingUnannounce"
        @unknown default:
            "unknown default"
        }
    }
}

extension QSubscribeTrackHandlerStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAuthorized:
            "notAuthorized"
        case .notConnected:
            "notConnected"
        case .notSubscribed:
            "notSubscribed"
        case .ok:
            "ok"
        case .pendingSubscribeResponse:
            "pendingSubscribeResponse"
        case .sendingUnsubscribe:
            "sendingUnsubscribe"
        case .subscribeError:
            "subscribeError"
        @unknown default:
            "unknown default"
        }
    }
}

extension QClientStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .clientConnecting:
            "clientConnecting"
        case .clientFailedToConnect:
            "clientFailedToConnect"
        case .clientNotConnected:
            "clientNotConnected"
        case .disconnecting:
            "disconnecting"
        case .internalError:
            "internalError"
        case .invalidParams:
            "invalidParams"
        case .notReady:
            "notReady"
        case .ready:
            "ready"
        @unknown default:
            "unknown default"
        }
    }
}

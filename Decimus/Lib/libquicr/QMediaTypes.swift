// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

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
            return "internalError"
        case .noPreviousObject:
            return "noPreviousObject"
        case .noSubscribers:
            return "noSubscribers"
        case .notAnnounced:
            return "notAnnounced"
        case .notAuthorized:
            return "notAuthorized"
        case .objectContinuationDataNeeded:
            return "objectContinuationDataNeeded"
        case .objectDataComplete:
            return "objectDataComplete"
        case .objectDataIncomplete:
            return "objectDataIncomplete"
        case .objectDataTooLarge:
            return "objectDataTooLarge"
        case .objectPayloadLengthExceeded:
            return "objectPayloadLengthExceeded"
        case .ok:
            return "ok"
        case .previousObjectNotCompleteMustStartNewGroup:
            return "previousObjectNotCompleteMustStartNewGroup"
        case .previousObjectNotCompleteMustStartNewTrack:
            return "previousObjectNotCompleteMustStartNewTrack"
        case .previousObjectTruncated:
            return "previousObjectTruncated"
        case .paused:
            return "paused"
        @unknown default:
            assert(false, "All QPublishObjectStatus cases MUST be mapped")
            return "unknown default"
        }
    }
}

extension QPublishTrackHandlerStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ok:
            return "ok"
        case .announceNotAuthorized:
            return "announceNotAuthorized"
        case .noSubscribers:
            return "noSubscribers"
        case .notAnnounced:
            return "notAnnounced"
        case .notConnected:
            return "notConnected"
        case .pendingAnnounceResponse:
            return "pendingAnnounceResponse"
        case .sendingUnannounce:
            return "sendingUnannounce"
        case .subscriptionUpdated:
            return "subscriptionUpdated"
        case .newGroupRequested:
            return "newGroupRequested"
        case .pendingPublishOk:
            return "pendingPublishOk"
        case .paused:
            return "paused"
        @unknown default:
            assert(false, "All QPublishTrackHandlerStatus cases MUST be mapped")
            return "unknown default"
        }
    }
}

extension QSubscribeTrackHandlerStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAuthorized:
            return "notAuthorized"
        case .notConnected:
            return "notConnected"
        case .notSubscribed:
            return "notSubscribed"
        case .ok:
            return "ok"
        case .pendingResponse:
            return "pendingResponse"
        case .sendingUnsubscribe:
            return "sendingUnsubscribe"
        case .error:
            return "error"
        case .paused:
            return "paused"
        case .newGroupRequested:
            return "New Group Requested"
        case .cancelled:
            return "Cancelled"
        case .doneByFin:
            return "Done by FIN"
        case .doneByReset:
            return "Done by RESET"
        @unknown default:
            assert(false, "All QSubscribeTrackHandlerStatus cases MUST be mapped")
            return "unknown default"
        }
    }
}

extension QClientStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .clientConnecting:
            return "clientConnecting"
        case .clientPendingServerSetup:
            return "clientPendingServerSetup"
        case .clientFailedToConnect:
            return "clientFailedToConnect"
        case .clientNotConnected:
            return "clientNotConnected"
        case .disconnecting:
            return "disconnecting"
        case .internalError:
            return "internalError"
        case .invalidParams:
            return "invalidParams"
        case .notReady:
            return "notReady"
        case .ready:
            return "ready"
        @unknown default:
            assert(false, "All QClientStatus cases MUST be mapped")
            return "unknown default"
        }
    }
}

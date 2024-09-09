// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Atomics

class Publication: QPublishTrackHandlerObjC, QPublishTrackHandlerCallbacks {
    internal var publish = ManagedAtomic(false)
    internal let profile: Profile

    init(profile: Profile, trackMode: QTrackMode, defaultPriority: UInt8, defaultTTL: UInt32) throws {
        self.profile = profile
        let fullTrackName = try FullTrackName(namespace: profile.namespace, name: "")
        super.init(fullTrackName: fullTrackName.getUnsafe(),
                   trackMode: trackMode,
                   defaultPriority: defaultPriority,
                   defaultTTL: defaultTTL)
        super.setCallbacks(self)
    }

    internal func statusChanged(_ status: QPublishTrackHandlerStatus) {
        let publish = switch status {
        case .announceNotAuthorized:
            false
        case .noSubscribers:
            false
        case .notAnnounced:
            false
        case .notConnected:
            false
        case .ok:
            true
        case .pendingAnnounceResponse:
            false
        case .sendingUnannounce:
            false
        @unknown default:
            false
        }
        self.publish.store(publish, ordering: .releasing)
    }
}

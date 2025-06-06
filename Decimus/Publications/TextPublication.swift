// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Publishes text messages.
class TextPublication: Publication {
    private let incrementing: Incrementing
    private let participantId: Data
    private let logger = DecimusLogger(TextPublication.self)

    private var currentGroupId: UInt64 = 0
    private var currentObjectId: UInt64 = 0

    /// Creates a new TextPublication.
    init(participantId: ParticipantId,
         incrementing: Incrementing,
         profile: Profile,
         trackMode: QTrackMode,
         submitter: (any MetricsSubmitter)?,
         endpointId: String,
         relayId: String) throws {
        self.participantId = withUnsafeBytes(of: participantId.aggregate) { Data($0) }
        self.incrementing = incrementing
        guard let priority = profile.priorities?.first,
              let ttl = profile.expiry?.first else {
            throw "Missing profile"
        }
        try super.init(profile: profile,
                       trackMode: trackMode,
                       defaultPriority: UInt8(priority),
                       defaultTTL: UInt16(ttl),
                       submitter: submitter,
                       endpointId: endpointId,
                       relayId: relayId,
                       logger: self.logger)
    }

    func sendMessage(_ message: String) {
        let data = message.utf8
        let headers = QObjectHeaders(groupId: self.currentGroupId,
                                     objectId: self.currentObjectId,
                                     payloadLength: UInt64(data.count),
                                     priority: nil,
                                     ttl: nil)
        let status = self.publishObject(headers,
                                        data: .init(data),
                                        extensions: [AppHeaderRegistry.participantId.rawValue: self.participantId])
        switch status {
        case .ok:
            break
        case .noSubscribers:
            self.logger.warning("No subscribers")
        default:
            self.logger.error("Failed to send message: \(status)")
            return
        }

        switch self.incrementing {
        case .group:
            self.currentGroupId += 1
        case .object:
            self.currentObjectId += 1
        }
    }
}

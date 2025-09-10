// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Publishes text messages.
class TextPublication: Publication {
    private let incrementing: Incrementing
    private let participantId: ParticipantId
    private let logger = DecimusLogger(TextPublication.self)
    private let sframeContext: SendSFrameContext?

    private var currentGroupId: UInt64
    private var currentObjectId: UInt64 = 0

    /// Creates a new TextPublication.
    init(participantId: ParticipantId,
         incrementing: Incrementing,
         profile: Profile,
         trackMode: QTrackMode,
         submitter: (any MetricsSubmitter)?,
         endpointId: String,
         relayId: String,
         sframeContext: SendSFrameContext?,
         startingGroupId: UInt64) throws {
        self.participantId = participantId
        self.incrementing = incrementing
        guard let priority = profile.priorities?.first,
              let ttl = profile.expiry?.first else {
            throw "Missing profile"
        }
        self.sframeContext = sframeContext
        self.currentGroupId = startingGroupId
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
        let data: Data
        if let sframeContext = self.sframeContext {
            do {
                data = try sframeContext.context.mutex.withLock { context in
                    try context.protect(epochId: sframeContext.currentEpoch,
                                        senderId: sframeContext.senderId,
                                        plaintext: .init(message.utf8))
                }
            } catch {
                self.logger.error("Failed to protect message: \(error.localizedDescription)")
                return
            }
        } else {
            data = Data(message.utf8)
        }

        let headers = QObjectHeaders(groupId: self.currentGroupId,
                                     objectId: self.currentObjectId,
                                     payloadLength: UInt64(data.count),
                                     priority: nil,
                                     ttl: nil)
        var extensions = HeaderExtensions()
        try? extensions.setHeader(.participantId(self.participantId))
        let status = self.publishObject(headers,
                                        data: data,
                                        extensions: extensions)
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

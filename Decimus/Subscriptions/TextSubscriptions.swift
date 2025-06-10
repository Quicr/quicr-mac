// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// A received text message.
struct TextMessage: Identifiable {
    enum Author {
        case me
        case participant(ParticipantId?)
    }

    let id = UUID()

    /// The participant who sent the message.
    let author: Author
    /// The text content of the message.
    let message: String
    /// The date and time when the message was received.
    let dateReceived: Date
}

/// A subscription manager for text messages.
@Observable
class TextSubscriptions {
    /// The list of received text messages.
    var messages: [TextMessage] = []
    private let logger = DecimusLogger(TextSubscriptions.self)
    private var registrations: [MultipleCallbackSubscription: Int] = [:]
    private let sframeContext: SFrameContext?

    init(sframeContext: SFrameContext?) {
        self.sframeContext = sframeContext
    }

    /// Add a subscription to track.
    /// - Parameter subscription: The subscription to add.
    func addSubscription(_ subscription: MultipleCallbackSubscription) {
        let token = subscription.addCallback { [weak self] in self?.callback(headers: $0, data: $1, extensions: $2) }
        self.registrations[subscription] = token
    }

    private func callback(headers: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        let participantId: ParticipantId?
        if let extensions,
           let participantIdData = extensions[AppHeaderRegistry.participantId.rawValue] {
            participantId = ParticipantId(participantIdData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        } else {
            self.logger.warning("Missing participant ID in text message")
            participantId = nil
        }

        let unprotected: Data
        if let sframeContext = self.sframeContext {
            do {
                unprotected = try sframeContext.mutex.withLock { try $0.unprotect(ciphertext: data) }
            } catch {
                self.logger.error("Failed to unprotect text message: \(error.localizedDescription)")
                return
            }
        } else {
            unprotected = data
        }

        guard let text = String(data: unprotected, encoding: .utf8) else {
            self.logger.error("Failed to decode text message from data")
            return
        }
        let message = TextMessage(author: .participant(participantId), message: text, dateReceived: .now)
        self.logger.debug("Received text message from \(String(describing: message.author)): \(message.message)")
        self.messages.append(message)
    }

    deinit {
        for (subscription, token) in self.registrations {
            subscription.removeCallback(token)
        }
    }
}

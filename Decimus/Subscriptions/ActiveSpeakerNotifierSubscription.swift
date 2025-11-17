// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class ActiveSpeakerNotifierSubscription: Subscription,
                                         ActiveSpeakerNotifier {
    private var callbacks: [CallbackToken: ActiveSpeakersChanged] = [:]
    private var token: CallbackToken = 0
    private let logger = DecimusLogger(ActiveSpeakerNotifierSubscription.self)
    private let decoder = JSONDecoder()

    init(profile: Profile,
         endpointId: String,
         relayId: String,
         submitter: MetricsSubmitter?,
         publisherInitiated: Bool,
         statusChanged: StatusCallback?) throws {
        try super.init(profile: profile,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: submitter,
                       priority: 0,
                       groupOrder: .originalPublisherOrder,
                       filterType: .latestGroup,
                       publisherInitiated: publisherInitiated,
                       statusCallback: statusChanged)
    }

    func registerActiveSpeakerCallback(_ callback: @escaping ActiveSpeakersChanged) -> CallbackToken {
        let token = self.token
        self.callbacks[token] = callback
        self.token += 1
        return token
    }

    func unregisterActiveSpeakerCallback(_ token: CallbackToken) {
        self.callbacks.removeValue(forKey: token)
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders,
                                 data: Data,
                                 extensions: HeaderExtensions?,
                                 immutableExtensions: HeaderExtensions?) {
        // Parse out the active speaker list.
        let participants: [ParticipantId]
        do {
            participants = try self.decoder.decode([ParticipantId].self, from: data)
        } catch {
            self.logger.error("Failed to decode active speaker list: \(error.localizedDescription)")
            return
        }
        self.logger.debug("Got active speaker participants: \(participants)")
        for callback in self.callbacks.values {
            callback(.init(participants))
        }
    }
}

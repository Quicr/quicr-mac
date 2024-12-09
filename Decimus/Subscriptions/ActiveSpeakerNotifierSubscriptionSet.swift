// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class ActiveSpeakerNotifierSubscriptionSet: QSubscribeTrackHandlerObjC, SubscriptionSet, QSubscribeTrackHandlerCallbacks, ActiveSpeakerNotifier {
    private var callbacks: [CallbackToken: ActiveSpeakersChanged] = [:]
    private var token: CallbackToken = 0
    let sourceId: SourceIDType
    let participantId: ParticipantId
    private let fullTrackName: FullTrackName
    private let logger = DecimusLogger(ActiveSpeakerNotifierSubscriptionSet.self)
    private let decoder = JSONDecoder()

    init(subscription: ManifestSubscription) throws {
        self.sourceId = subscription.sourceID
        self.participantId = subscription.participantId
        guard subscription.profileSet.profiles.count == 1 else {
            throw "Expected exactly one profile"
        }
        self.fullTrackName = try subscription.profileSet.profiles.first!.getFullTrackName()
        super.init(fullTrackName: self.fullTrackName, priority: 0, groupOrder: .originalPublisherOrder, filterType: .latestGroup)
        super.setCallbacks(self)
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

    func getHandlers() -> [FullTrackName: QSubscribeTrackHandlerObjC] {
        [self.fullTrackName: self]
    }

    func removeHandler(_ ftn: FullTrackName) -> QSubscribeTrackHandlerObjC? {
        nil
    }

    func addHandler(_ handler: QSubscribeTrackHandlerObjC) throws { }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.info("Status changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        // Parse out the active speaker list.
        do {
            let participants = try self.decoder.decode([ParticipantId].self, from: data)
            self.logger.debug("Got active speaker participants: \(participants)")
            for callback in self.callbacks.values {
                callback(.init(participants))
            }
        } catch {
            self.logger.error("Failed to decode active speaker list: \(error.localizedDescription)")
        }
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        self.logger.warning("Unexpected partial object received")
    }

    func metricsSampled(_ metrics: QSubscribeTrackMetrics) {
        // TODO: Metrics.
    }
}

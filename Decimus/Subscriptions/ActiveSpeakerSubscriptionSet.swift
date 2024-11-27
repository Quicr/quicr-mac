// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Subscription set for handling active speaker audio arriving on multiple tracks.
class ActiveSpeakerSubscriptionSet: SubscriptionSet {
    let participantId: ParticipantId
    let sourceId: SourceIDType

    // Dependencies.
    private let logger = DecimusLogger(ActiveSpeakerSubscriptionSet.self)
    private let engine: DecimusAudioEngine
    private let jitterDepth: TimeInterval
    private let jitterMax: TimeInterval
    private let opusWindowSize: OpusWindowSize
    private let ourParticipantId: ParticipantId?

    /// Individual active speaker subscriptions.
    private var handlers: [FullTrackName: QSubscribeTrackHandlerObjC] = [:]
    /// Per-client audio media objects.
    private var audioMediaObjects: [ParticipantId: OpusHandler] = [:]

    init(subscription: ManifestSubscription,
         engine: DecimusAudioEngine,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         ourParticipantId: ParticipantId?) {
        self.participantId = subscription.participantId
        self.sourceId = subscription.sourceID
        self.engine = engine
        self.jitterDepth = jitterDepth
        self.jitterMax = jitterMax
        self.opusWindowSize = opusWindowSize
        self.ourParticipantId = ourParticipantId
    }

    func getHandlers() -> [FullTrackName: QSubscribeTrackHandlerObjC] {
        self.handlers
    }

    func removeHandler(_ ftn: FullTrackName) -> QSubscribeTrackHandlerObjC? {
        self.handlers.removeValue(forKey: ftn)
    }

    func addHandler(_ handler: QSubscribeTrackHandlerObjC) throws {
        let ftn = FullTrackName(handler.getFullTrackName())
        self.handlers[ftn] = handler
    }

    /// Provide encoded active speaker audio from a constituent track.
    /// - Parameter headers: The headers for the object.
    /// - Parameter data: The encoded audio data.
    /// - Parameter extensions: The extensions for the object, if any.
    func receivedObject(headers: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        // Extract the client ID from the header.
        guard let extensions = extensions,
              let participantIdextension = extensions[OpusPublication.participantIdKey] else {
            self.logger.error("Missing expected client ID extension")
            return
        }

        // Parse.
        let extracted = participantIdextension.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let participantId = ParticipantId(extracted)
        if let ourParticipantId = self.ourParticipantId,
           participantId == ourParticipantId {
            // Ignoring our own audio.
            return
        }

        // Look up the media object for this client, or create one.
        let media: OpusHandler
        if let existing = self.audioMediaObjects[participantId] {
            media = existing
        } else {
            do {
                media = try OpusHandler(sourceId: "\(participantId)",
                                        engine: self.engine,
                                        measurement: nil,
                                        jitterDepth: self.jitterDepth,
                                        jitterMax: self.jitterMax,
                                        opusWindowSize: self.opusWindowSize,
                                        granularMetrics: false,
                                        useNewJitterBuffer: true,
                                        metricsSubmitter: nil)
                self.audioMediaObjects[participantId] = media
            } catch {
                self.logger.error("Failed to create audio handler for active speaker participant: \(error.localizedDescription)")
                return
            }
        }

        // Decode the LOC here.
        do {
            let loc = try LowOverheadContainer(from: extensions)
            try media.submitEncodedAudio(data: data, sequence: loc.sequence, date: Date.now, timestamp: loc.timestamp)
        } catch {
            self.logger.error("Failed to decode LOC: \(error.localizedDescription)")
        }
    }
}

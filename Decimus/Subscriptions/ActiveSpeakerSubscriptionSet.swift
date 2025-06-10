// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Subscription set for handling active speaker audio arriving on multiple tracks.
class ActiveSpeakerSubscriptionSet: ObservableSubscriptionSet {
    // Dependencies.
    private let logger = DecimusLogger(ActiveSpeakerSubscriptionSet.self)
    private let engine: DecimusAudioEngine
    private let ourParticipantId: ParticipantId?
    private let metricsSubmitter: MetricsSubmitter?
    private let activeSpeakerStats: ActiveSpeakerStats?

    /// Individual active speaker subscriptions.
    private var handlers: [FullTrackName: QSubscribeTrackHandlerObjC] = [:]
    /// Per-client audio media objects.
    private var audioMediaObjects: [ParticipantId: AudioHandler] = [:]

    private let audioHandlerConfig: AudioHandler.Config

    init(subscription: ManifestSubscription,
         engine: DecimusAudioEngine,
         ourParticipantId: ParticipantId?,
         submitter: MetricsSubmitter?,
         activeSpeakerStats: ActiveSpeakerStats?,
         config: AudioHandler.Config) {
        self.engine = engine
        self.ourParticipantId = ourParticipantId
        self.metricsSubmitter = submitter
        self.activeSpeakerStats = activeSpeakerStats
        self.audioHandlerConfig = config
        super.init(sourceId: subscription.sourceID, participantId: subscription.participantId)
    }

    /// Provide encoded active speaker audio from a constituent track.
    /// - Parameter headers: The headers for the object.
    /// - Parameter data: The encoded audio data.
    /// - Parameter extensions: The extensions for the object, if any.
    func receivedObject(headers: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        // Extract the client ID from the header.
        guard let extensions = extensions,
              let participantIdextension = extensions[AppHeaderRegistry.participantId.rawValue] else {
            self.logger.error("Missing expected client ID extension")
            return
        }

        // Parse.
        let participantId: ParticipantId
        do {
            let extracted = try LowOverheadContainer.parse(participantIdextension)
            participantId = ParticipantId(UInt32(extracted))
        } catch {
            self.logger.error("Failed to extract participant ID: \(error.localizedDescription)")
            return
        }
        if let ourParticipantId = self.ourParticipantId,
           participantId == ourParticipantId {
            // Ignoring our own audio.
            return
        }

        // Metrics.
        let now = Date.now
        if let activeSpeakerStats = self.activeSpeakerStats {
            Task(priority: .utility) {
                await activeSpeakerStats.audioDetected(participantId,
                                                       when: now)
            }
        }

        // Look up the media object for this client, or create one.
        let media: AudioHandler
        if let existing = self.audioMediaObjects[participantId] {
            media = existing
        } else {
            // Metrics.
            let measurement: MeasurementRegistration<OpusSubscription.OpusSubscriptionMeasurement>?
            if let submitter = self.metricsSubmitter {
                measurement = .init(measurement: .init(namespace: "\(participantId)"), submitter: submitter)
            } else {
                measurement = nil
            }

            // Create the handler.
            do {
                media = try AudioHandler(identifier: "\(participantId)",
                                         engine: self.engine,
                                         decoder: LibOpusDecoder(format: DecimusAudioEngine.format),
                                         measurement: measurement,
                                         metricsSubmitter: self.metricsSubmitter,
                                         config: self.audioHandlerConfig)
                self.audioMediaObjects[participantId] = media
            } catch {
                self.logger.error(
                    "Failed to create audio handler for active speaker participant: \(error.localizedDescription)")
                return
            }
        }

        // Decode the LOC here.
        do {
            let loc = try LowOverheadContainer(from: extensions)
            try media.submitEncodedAudio(data: data,
                                         sequence: headers.groupId,
                                         date: now,
                                         timestamp: loc.timestamp)
        } catch {
            self.logger.error("Failed to decode LOC: \(error.localizedDescription)")
        }
    }
}

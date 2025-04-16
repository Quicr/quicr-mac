// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Subscription set for handling active speaker audio arriving on multiple tracks.
class ActiveSpeakerSubscriptionSet: ObservableSubscriptionSet {
    // Dependencies.
    private let logger = DecimusLogger(ActiveSpeakerSubscriptionSet.self)
    private let engine: DecimusAudioEngine
    private let jitterDepth: TimeInterval
    private let jitterMax: TimeInterval
    private let opusWindowSize: OpusWindowSize
    private let ourParticipantId: ParticipantId?
    private let metricsSubmitter: MetricsSubmitter?
    private let useNewJitterBuffer: Bool
    private let granularMetrics: Bool
    private let activeSpeakerStats: ActiveSpeakerStats?

    /// Individual active speaker subscriptions.
    private var handlers: [FullTrackName: QSubscribeTrackHandlerObjC] = [:]
    /// Per-client audio media objects.
    private var audioMediaObjects: [ParticipantId: AudioHandler] = [:]

    init(subscription: ManifestSubscription,
         engine: DecimusAudioEngine,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         ourParticipantId: ParticipantId?,
         submitter: MetricsSubmitter?,
         useNewJitterBuffer: Bool,
         granularMetrics: Bool,
         activeSpeakerStats: ActiveSpeakerStats?) {
        self.engine = engine
        self.jitterDepth = jitterDepth
        self.jitterMax = jitterMax
        self.opusWindowSize = opusWindowSize
        self.ourParticipantId = ourParticipantId
        self.metricsSubmitter = submitter
        self.useNewJitterBuffer = useNewJitterBuffer
        self.granularMetrics = granularMetrics
        self.activeSpeakerStats = activeSpeakerStats
        super.init(sourceId: subscription.sourceID, participantId: subscription.participantId)
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
                                         jitterDepth: self.jitterDepth,
                                         jitterMax: self.jitterMax,
                                         opusWindowSize: self.opusWindowSize,
                                         granularMetrics: self.granularMetrics,
                                         useNewJitterBuffer: self.useNewJitterBuffer,
                                         metricsSubmitter: self.metricsSubmitter)
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
            try media.submitEncodedAudio(data: data, sequence: loc.sequence ?? headers.objectId, date: now, timestamp: loc.timestamp)
        } catch {
            self.logger.error("Failed to decode LOC: \(error.localizedDescription)")
        }
    }
}

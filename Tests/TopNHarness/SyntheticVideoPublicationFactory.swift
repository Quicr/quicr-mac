// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization
@testable import QuicR

final class SyntheticVideoPublicationFactory: PublicationFactory, @unchecked Sendable {
    private let fixtures: TopNH264FixtureSet
    private let startingGroupId: UInt64
    private let startingRollReason: TopNGroupRollReason
    private let participant: TopNParticipantID
    private let connectionGeneration: UInt64
    private let faultController: TopNHarnessFaultController
    private let onPublished: @Sendable (TopNPublishedObject) -> Void
    private let onStatus: @Sendable (TopNVideoQuality, QPublishTrackHandlerStatus) -> Void
    private let created = Mutex<SyntheticVideoPublication?>(nil)

    init(fixtures: TopNH264FixtureSet,
         startingGroupId: UInt64,
         startingRollReason: TopNGroupRollReason,
         participant: TopNParticipantID,
         connectionGeneration: UInt64,
         faultController: TopNHarnessFaultController,
         onPublished: @escaping @Sendable (TopNPublishedObject) -> Void,
         onStatus: @escaping @Sendable (TopNVideoQuality, QPublishTrackHandlerStatus) -> Void) {
        self.fixtures = fixtures
        self.startingGroupId = startingGroupId
        self.startingRollReason = startingRollReason
        self.participant = participant
        self.connectionGeneration = connectionGeneration
        self.faultController = faultController
        self.onPublished = onPublished
        self.onStatus = onStatus
    }

    func create(publication: ManifestPublication,
                codecFactory: CodecFactory,
                endpointId: String,
                relayId: String) throws -> [(FullTrackName, any PublicationInstance)] {
        _ = endpointId
        _ = relayId
        guard publication.profileSet.profiles.count == TopNVideoQuality.allCases.count else {
            throw PubSubFactoryError.cannotCreate("Top-N synthetic publication requires three profiles")
        }

        let profiles = try Dictionary(uniqueKeysWithValues: publication.profileSet.profiles.map { profile in
            let components = profile.namespace
            guard components.count == 5,
                  let quality = TopNVideoQuality(rawValue: components[3]),
                  components[4] == self.participant.rawValue,
                  profile.name == "h264",
                  profile.qualityProfile == quality.qualityProfile else {
                throw PubSubFactoryError.cannotCreate("Invalid Top-N simulreceive profile")
            }
            let config = codecFactory.makeCodecConfig(from: profile.qualityProfile, bitrateType: .average)
            guard let videoConfig = config as? VideoCodecConfig,
                  videoConfig.codec == .h264,
                  videoConfig.width == Int32(quality.width),
                  videoConfig.height == Int32(quality.height) else {
                throw PubSubFactoryError.cannotCreate("Top-N synthetic publication requires matching H.264 profiles")
            }
            return (quality, profile)
        })
        guard profiles.count == TopNVideoQuality.allCases.count else {
            throw PubSubFactoryError.cannotCreate("Top-N synthetic publication requires unique qualities")
        }

        let tracks = try TopNVideoQuality.allCases.map { quality in
            let profile = profiles[quality]!
            let fullTrackName = try profile.getFullTrackName()
            let sink = QPublishTrackHandlerSink(fullTrackName: fullTrackName,
                                                trackMode: .stream,
                                                defaultPriority: try profile.getPriority(index: 0),
                                                defaultTTL: UInt32(try profile.getTTL(index: 0)))
            return SyntheticVideoPublicationTrack(quality: quality, profile: profile, sink: sink)
        }
        let publication = SyntheticVideoPublication(fixtures: self.fixtures,
                                                    tracks: tracks,
                                                    startingGroupId: self.startingGroupId,
                                                    startingRollReason: self.startingRollReason,
                                                    participant: self.participant,
                                                    connectionGeneration: self.connectionGeneration,
                                                    faultController: self.faultController,
                                                    onPublished: self.onPublished,
                                                    onStatus: self.onStatus)
        self.created.withLock { $0 = publication }
        return tracks.map { ($0.sink.fullTrackName, $0 as any PublicationInstance) }
    }

    func takeCreatedPublication() throws -> SyntheticVideoPublication {
        let publication = self.created.withLock { value in
            let result = value
            value = nil
            return result
        }
        guard let publication else {
            throw PubSubFactoryError.cannotCreate("Synthetic publication was not created")
        }
        return publication
    }
}

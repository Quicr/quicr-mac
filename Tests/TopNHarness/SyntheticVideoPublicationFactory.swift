// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization
@testable import QuicR

final class SyntheticVideoPublicationFactory: PublicationFactory, @unchecked Sendable {
    private let fixture: TopNH264Fixture
    private let startingGroupId: UInt64
    private let startingRollReason: TopNGroupRollReason
    private let participant: TopNParticipantID
    private let connectionGeneration: UInt64
    private let faultController: TopNHarnessFaultController
    private let onPublished: @Sendable (TopNPublishedObject) -> Void
    private let onStatus: @Sendable (QPublishTrackHandlerStatus) -> Void
    private let created = Mutex<SyntheticVideoPublication?>(nil)

    init(fixture: TopNH264Fixture,
         startingGroupId: UInt64,
         startingRollReason: TopNGroupRollReason,
         participant: TopNParticipantID,
         connectionGeneration: UInt64,
         faultController: TopNHarnessFaultController,
         onPublished: @escaping @Sendable (TopNPublishedObject) -> Void,
         onStatus: @escaping @Sendable (QPublishTrackHandlerStatus) -> Void) {
        self.fixture = fixture
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
        guard publication.profileSet.profiles.count == 1,
              let profile = publication.profileSet.profiles.first else {
            throw PubSubFactoryError.cannotCreate("Top-N synthetic publication requires one profile")
        }
        let config = codecFactory.makeCodecConfig(from: profile.qualityProfile, bitrateType: .average)
        guard let videoConfig = config as? VideoCodecConfig, videoConfig.codec == .h264 else {
            throw PubSubFactoryError.cannotCreate("Top-N synthetic publication requires H.264")
        }
        let fullTrackName = try profile.getFullTrackName()
        let sink = QPublishTrackHandlerSink(fullTrackName: fullTrackName,
                                            trackMode: .stream,
                                            defaultPriority: try profile.getPriority(index: 0),
                                            defaultTTL: UInt32(try profile.getTTL(index: 0)))
        let publication = SyntheticVideoPublication(profile: profile,
                                                    fixture: self.fixture,
                                                    startingGroupId: self.startingGroupId,
                                                    startingRollReason: self.startingRollReason,
                                                    participant: self.participant,
                                                    connectionGeneration: self.connectionGeneration,
                                                    faultController: self.faultController,
                                                    onPublished: self.onPublished,
                                                    onStatus: self.onStatus,
                                                    sink: sink)
        self.created.withLock { $0 = publication }
        return [(fullTrackName, publication)]
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

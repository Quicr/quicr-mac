// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization
@testable import QuicR

@MainActor
final class TopNHarnessParticipant {
    struct Generation {
        let number: UInt64
        let client: QClientObjC
        let controller: MoqCallController
        let videoParticipants: VideoParticipants
        let namespaceHandlers: [QSubscribeNamespaceHandler]
        let publication: SyntheticVideoPublication
    }

    private struct ReceiveContext {
        let controller: MoqCallController
        let subscriptionFactory: SubscriptionFactoryImpl
        let namespaceHandlers: [QSubscribeNamespaceHandler]
    }

    let id: TopNParticipantID
    private let participantIndex: UInt16
    private let configuration: TopNHarnessConfiguration
    private let fixtures: TopNH264FixtureSet
    private let recorder: TopNHarnessRecorder
    private let faultController: TopNHarnessFaultController
    private let isParticipantEligible: @MainActor (TopNParticipantID) -> Bool
    private let onVideoParticipantsReady: @MainActor (VideoParticipants) -> Void
    private(set) var generationNumber: UInt64 = 0
    private(set) var generation: Generation?
    private(set) var retainedLastSuccessfulGroupId: UInt64?
    private var receiveContext: ReceiveContext?

    init(id: TopNParticipantID,
         participantIndex: UInt16,
         configuration: TopNHarnessConfiguration,
         fixtures: TopNH264FixtureSet,
         recorder: TopNHarnessRecorder,
         faultController: TopNHarnessFaultController,
         isParticipantEligible: @escaping @MainActor (TopNParticipantID) -> Bool,
         onVideoParticipantsReady: @escaping @MainActor (VideoParticipants) -> Void) {
        self.id = id
        self.participantIndex = participantIndex
        self.configuration = configuration
        self.fixtures = fixtures
        self.recorder = recorder
        self.faultController = faultController
        self.isParticipantEligible = isParticipantEligible
        self.onVideoParticipantsReady = onVideoParticipantsReady
    }

    private func makeNamespaceHandlers() -> [QSubscribeNamespaceHandler] {
        TopNVideoQuality.allCases.map { quality in
            let filter = QTrackFilterObjC(propertyType: AppHeadersRegistry.audioActivityIndicator.rawValue,
                                          maxTracksSelected: UInt64(self.configuration.topN),
                                          timeout: self.configuration.filterTimeoutMilliseconds)
            return QSubscribeNamespaceHandler(
                namespacePrefix: NamespacePrefix(quality.subscribeNamespace(meetingID: self.configuration.meetingID)),
                trackFilter: filter) { _, _, _ in }
        }
    }

    func join(startingGroupId: UInt64,
              startingRollReason: TopNGroupRollReason) async throws {
        guard self.generation == nil else { return }
        self.generationNumber += 1
        let number = self.generationNumber
        let qlogPath = URL(fileURLWithPath: self.configuration.artifactDirectory)
            .appendingPathComponent("clients", isDirectory: true)
            .appendingPathComponent(self.id.rawValue, isDirectory: true)
            .appendingPathComponent("generation-\(number)", isDirectory: true)
            .appendingPathComponent("qlog", isDirectory: true)
        try FileManager.default.createDirectory(at: qlogPath, withIntermediateDirectories: true)
        let endpoint = "topn-\(self.id.rawValue)-generation-\(number)"
        let makeClient: (UnsafePointer<CChar>?) -> QClientObjC = { qlogPathPointer in
            let transport = TransportConfig(tls_cert_filename: nil, tls_key_filename: nil,
                                            time_queue_init_queue_size: 150_000, time_queue_max_duration: 750_000,
                                            time_queue_bucket_interval: 1, time_queue_rx_size: 500, debug: true,
                                            quic_cwin_minimum: 8 * 1024, quic_wifi_shadow_rtt_us: 0,
                                            idle_timeout_ms: 15_000, congestion_control: .bbr,
                                            quic_qlog_path: qlogPathPointer,
                                            quic_priority_limit: 0, max_connections: 1, ssl_keylog: false,
                                            socket_buffer_size: 1_000_000)
            return self.configuration.relayURI.withCString { uri in
                endpoint.withCString { endpoint in
                    QClientObjC(config: .init(connectUri: uri,
                                              endpointId: endpoint,
                                              transportConfig: transport,
                                              metricsSampleMs: 5000))
                }
            }
        }
        let client = if self.configuration.enableQlog {
            qlogPath.path.withCString { makeClient($0) }
        } else {
            makeClient(nil)
        }
        let controller = MoqCallController(endpointUri: endpoint,
                                           client: client,
                                           submitter: nil,
                                           publishReceived: { [weak self] tfn, attributes, handler in
                                            guard let self else { return .reject }
                                            return await self.acceptRemote(tfn: .init(tfn),
                                                                           attributes: attributes,
                                                                           namespaceHandler: handler)
                                           },
                                           callEnded: nil)
        let participants = VideoParticipants()
        participants.displayOrder = .recentActivity
        participants.maxDisplayCount = self.configuration.topN
        self.onVideoParticipantsReady(participants)
        var subConfig = SubscriptionConfig()
        subConfig.joinConfig = .init(fetchUpperThreshold: self.configuration.joinPolicy.fetchUpperThresholdSeconds,
                                     newGroupUpperThreshold: self.configuration.joinPolicy.newGroupUpperThresholdSeconds)
        subConfig.keyFrameInterval = 5
        subConfig.simulreceive = .enable
        subConfig.qualityHitThreshold = 1
        subConfig.qualityMissThreshold = 1
        subConfig.enableQlog = self.configuration.enableQlog
        subConfig.stalenessThreshold = 0.3
        participants.stalenessThreshold = subConfig.stalenessThreshold
        participants.startStalenessChecks()
        let localParticipant = self.id
        let meetingID = self.configuration.meetingID
        let faultController = self.faultController
        let factory = SubscriptionFactoryImpl(videoParticipants: participants,
                                              metricsSubmitter: nil,
                                              subscriptionConfig: subConfig,
                                              granularMetrics: false,
                                              engine: nil,
                                              participantId: ParticipantId(UInt32(self.participantIndex)),
                                              joinDate: .now,
                                              activeSpeakerStats: nil,
                                              controller: controller,
                                              verbose: false,
                                              startingGroup: nil,
                                              manualActiveSpeaker: false,
                                              sframeContext: nil,
                                              calculateLatency: false,
                                              mediaInterop: false,
                                              videoPipelineEvent: self.recorder.videoCallback(client: self.id,
                                                                                              connectionGeneration: number),
                                              videoObjectIngressInterceptor: { ingress in
                                                guard let remote = Self.remoteTrack(
                                                        in: ingress.fullTrackName, meetingID: meetingID)?.participant else {
                                                    return .deliver
                                                }
                                                return faultController.ingressDecision(localParticipant: localParticipant,
                                                                                       remoteParticipant: remote,
                                                                                       connectionGeneration: number,
                                                                                       ingress: ingress)
                                              })
        let namespaceHandlers = self.makeNamespaceHandlers()
        self.receiveContext = .init(controller: controller,
                                    subscriptionFactory: factory,
                                    namespaceHandlers: namespaceHandlers)
        var joined = false
        defer {
            if !joined {
                self.receiveContext = nil
                participants.stopStalenessChecks()
                try? controller.disconnect()
            }
        }
        try await controller.connect()
        for namespaceHandler in namespaceHandlers {
            try controller.subscribeNamespace(namespaceHandler)
        }
        let publicationFactory = SyntheticVideoPublicationFactory(fixtures: self.fixtures,
                                                                  startingGroupId: startingGroupId,
                                                                  startingRollReason: startingRollReason,
                                                                  participant: self.id,
                                                                  connectionGeneration: number,
                                                                  faultController: self.faultController,
                                                                  onPublished: { [weak self] object in
                                                                    self?.recordPublished(object, generation: number)
                                                                  },
                                                                  onStatus: { [weak self] quality, status in
                                                                    self?.recordPublicationStatus(
                                                                        quality, status: status, generation: number)
                                                                  })
        let publicationDetails = ManifestPublication(mediaType: "video", sourceName: "synthetic",
                                                     sourceID: "topn-\(self.id.rawValue)-video",
                                                     label: "Top-N synthetic video",
                                                     profileSet: .init(
                                                        type: "video",
                                                        profiles: TopNVideoQuality.allCases.map { quality in
                                                            .init(
                                                                qualityProfile: quality.qualityProfile,
                                                                expiry: [5000, 5000], priorities: [2, 3],
                                                                namespace: quality.publicationNamespace(
                                                                    meetingID: self.configuration.meetingID,
                                                                    participant: self.id),
                                                                name: "h264")
                                                        }))
        _ = try controller.publish(details: publicationDetails,
                                   factory: publicationFactory,
                                   codecFactory: CodecFactoryImpl())
        let publication = try publicationFactory.takeCreatedPublication()
        self.generation = .init(number: number, client: client, controller: controller,
                                videoParticipants: participants, namespaceHandlers: namespaceHandlers,
                                publication: publication)
        joined = true
        publication.start()
    }

    func setActivity(_ activity: TopNActivity, actionID: String) throws {
        guard let publication = self.generation?.publication else { throw MoqCallControllerError.notConnected }
        publication.setActivity(activity, actionID: actionID)
    }

    func videoView(for publisher: TopNParticipantID) -> VideoView? {
        let expectedID = "topn-\(publisher.rawValue)-video"
        var result: VideoView?
        self.generation?.videoParticipants.forEachParticipant { participant in
            guard participant.id == expectedID, participant.display else { return }
            result = participant.view
        }
        return result
    }

    func leave(reason: String) async {
        guard let generation = self.generation else { return }
        await generation.publication.stop()
        self.retainedLastSuccessfulGroupId = generation.publication.lastSuccessfulGroupId
        generation.videoParticipants.stopStalenessChecks()
        self.receiveContext = nil
        try? generation.controller.disconnect()
        self.generation = nil
        _ = reason
    }

    private func acceptRemote(tfn: FullTrackName,
                              attributes: QPublishAttributes,
                              namespaceHandler _: (any MoQSubscribeNamespaceHandler)?) async -> PublishResponse {
        let remoteTrack = Self.remoteTrack(in: tfn, meetingID: self.configuration.meetingID)
        let offeredParticipant = remoteTrack?.participant
        self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: self.generationNumber,
                                         remoteParticipant: offeredParticipant, stage: .publishOffered,
                                         details: .init(quality: remoteTrack?.quality))
        guard let receiveContext = self.receiveContext else {
            return self.rejectRemote(offeredParticipant, reason: "receive context unavailable")
        }
        guard let remoteTrack else {
            return self.rejectRemote(nil, reason: "unexpected full track name")
        }
        let remote = remoteTrack.participant
        guard remote != self.id else {
            return self.rejectRemote(remote, reason: "self publication")
        }
        guard self.configuration.participants.contains(remote), self.isParticipantEligible(remote) else {
            return self.rejectRemote(remote, reason: "participant unavailable")
        }
        let profiles = TopNVideoQuality.allCases.map { quality in
            Profile(qualityProfile: quality.qualityProfile,
                    expiry: [5000, 5000], priorities: [2, 3],
                    namespace: quality.publicationNamespace(
                        meetingID: self.configuration.meetingID, participant: remote),
                    name: "h264")
        }
        let details = ManifestSubscription(mediaType: "video", sourceName: "synthetic",
                                           sourceID: "topn-\(remote.rawValue)-video", label: "Top-N synthetic video",
                                           participantId: ParticipantId(UInt32(self.configuration.participants.firstIndex(of: remote)! + 1)),
                                           profileSet: .init(type: "video", profiles: profiles))
        let pubDetails = MoqCallController.PublisherInitiatedDetails(trackAlias: attributes.trackAlias,
                                                                     requestId: attributes.newGroupRequestId)
        let set: SubscriptionSet
        do {
            if let existing = receiveContext.controller.getSubscriptionSet(details.sourceID) {
                set = existing
            } else {
                set = try receiveContext.controller.subscribeToSet(
                    details: details, factory: receiveContext.subscriptionFactory, subscribeType: .setOnly)
            }
            guard set.getHandlers()[tfn] == nil else {
                return self.rejectRemote(remote, reason: "duplicate quality offer")
            }
            let profile = profiles.first { $0.namespace[3] == remoteTrack.quality.rawValue }!
            let subscription = try receiveContext.controller.subscribe(
                set: set, profile: profile, factory: receiveContext.subscriptionFactory,
                publisherInitiated: pubDetails)
            var response = attributes
            response.filterType = .latestObject
            response.forward = 1
            response.isPublisherInitiated = true
            self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: self.generationNumber,
                                             remoteParticipant: remote, stage: .publishAccepted,
                                             details: .init(quality: remoteTrack.quality))
            return .accept(response, subscription)
        } catch {
            return self.rejectRemote(remote, reason: "subscription creation failed: \(error)")
        }
    }

    private func rejectRemote(_ remote: TopNParticipantID?, reason: String) -> PublishResponse {
        self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: self.generationNumber,
                                         remoteParticipant: remote, stage: .publishRejected,
                                         details: .init(reason: reason))
        return .reject
    }

    private struct RemoteTrack {
        let participant: TopNParticipantID
        let quality: TopNVideoQuality
    }

    nonisolated private static func remoteTrack(in tfn: FullTrackName,
                                                meetingID: String) -> RemoteTrack? {
        let components = tfn.nameSpace.compactMap { String(data: $0, encoding: .utf8) }
        guard components.count == 5,
              components[0] == "meetings.wbx.com",
              components[1] == meetingID,
              components[2] == "video",
              let quality = TopNVideoQuality(rawValue: components[3]),
              String(data: tfn.name, encoding: .utf8) == "h264" else { return nil }
        return .init(participant: TopNParticipantID(rawValue: components[4]), quality: quality)
    }

    nonisolated private func recordPublished(_ object: TopNPublishedObject, generation: UInt64) {
        self.recorder.recordHarnessEvent(
            client: self.id, connectionGeneration: generation,
            groupId: object.groupId, subgroupId: object.subgroupId,
            objectId: object.objectId, actionID: object.activityActionID,
            stage: .publishedObject,
            details: .init(rollReason: object.rollReason?.rawValue))
    }

    nonisolated private func recordPublicationStatus(_ quality: TopNVideoQuality,
                                                     status: QPublishTrackHandlerStatus,
                                                     generation: UInt64) {
        self.recorder.recordHarnessEvent(
            client: self.id, connectionGeneration: generation,
            stage: .publicationStatus,
            details: .init(status: "\(quality.rawValue):\(status)"))
    }
}

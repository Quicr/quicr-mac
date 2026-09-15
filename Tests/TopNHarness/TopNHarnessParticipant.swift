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
        let namespaceHandler: QSubscribeNamespaceHandler
        let publication: SyntheticVideoPublication
    }

    private struct ReceiveContext {
        let controller: MoqCallController
        let subscriptionFactory: SubscriptionFactoryImpl
        let namespaceHandler: QSubscribeNamespaceHandler
    }

    let id: TopNParticipantID
    private let participantIndex: UInt16
    private let configuration: TopNHarnessConfiguration
    private let fixture: TopNH264Fixture
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
         fixture: TopNH264Fixture,
         recorder: TopNHarnessRecorder,
         faultController: TopNHarnessFaultController,
         isParticipantEligible: @escaping @MainActor (TopNParticipantID) -> Bool,
         onVideoParticipantsReady: @escaping @MainActor (VideoParticipants) -> Void) {
        self.id = id
        self.participantIndex = participantIndex
        self.configuration = configuration
        self.fixture = fixture
        self.recorder = recorder
        self.faultController = faultController
        self.isParticipantEligible = isParticipantEligible
        self.onVideoParticipantsReady = onVideoParticipantsReady
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
                                                guard let remote = Self.remoteParticipant(in: ingress.fullTrackName, meetingID: meetingID) else {
                                                    return .deliver
                                                }
                                                return faultController.ingressDecision(localParticipant: localParticipant,
                                                                                       remoteParticipant: remote,
                                                                                       connectionGeneration: number,
                                                                                       ingress: ingress)
                                              })
        let prefix = NamespacePrefix(["meetings.wbx.com", self.configuration.meetingID, "video"])
        let filter = QTrackFilterObjC(propertyType: AppHeadersRegistry.audioActivityIndicator.rawValue,
                                      maxTracksSelected: UInt64(self.configuration.topN),
                                      timeout: self.configuration.filterTimeoutMilliseconds)
        let namespaceHandler = QSubscribeNamespaceHandler(namespacePrefix: prefix,
                                                          trackFilter: filter) { _, _, _ in }
        self.receiveContext = .init(controller: controller,
                                    subscriptionFactory: factory,
                                    namespaceHandler: namespaceHandler)
        var joined = false
        defer {
            if !joined {
                self.receiveContext = nil
                participants.stopStalenessChecks()
                try? controller.disconnect()
            }
        }
        try await controller.connect()
        try controller.subscribeNamespace(namespaceHandler)
        let publicationFactory = SyntheticVideoPublicationFactory(fixture: self.fixture,
                                                                  startingGroupId: startingGroupId,
                                                                  startingRollReason: startingRollReason,
                                                                  participant: self.id,
                                                                  connectionGeneration: number,
                                                                  faultController: self.faultController,
                                                                  onPublished: { [weak self] object in
                                                                    guard let self else { return }
                                                                    self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: number,
                                                                                                     groupId: object.groupId, subgroupId: object.subgroupId,
                                                                                                     objectId: object.objectId, actionID: object.activityActionID,
                                                                                                     stage: .publishedObject,
                                                                                                     details: .init(rollReason: object.rollReason?.rawValue))
                                                                  },
                                                                  onStatus: { [weak self] status in
                                                                    guard let self else { return }
                                                                    self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: number,
                                                                                                     stage: .publicationStatus,
                                                                                                     details: .init(status: String(describing: status)))
                                                                  })
        let publicationDetails = ManifestPublication(mediaType: "video", sourceName: "synthetic",
                                                     sourceID: "topn-\(self.id.rawValue)-video",
                                                     label: "Top-N synthetic video",
                                                     profileSet: .init(type: "video", profiles: [
                                                        .init(qualityProfile: "h264,width=320,height=180,fps=30,br=400",
                                                              expiry: [5000, 5000], priorities: [2, 3],
                                                              namespace: ["meetings.wbx.com", self.configuration.meetingID,
                                                                          "video", self.id.rawValue], name: "h264")
                                                     ]))
        _ = try controller.publish(details: publicationDetails,
                                   factory: publicationFactory,
                                   codecFactory: CodecFactoryImpl())
        let publication = try publicationFactory.takeCreatedPublication()
        self.generation = .init(number: number, client: client, controller: controller,
                                videoParticipants: participants, namespaceHandler: namespaceHandler,
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
        let components = tfn.nameSpace.compactMap { String(data: $0, encoding: .utf8) }
        let remote = Self.remoteParticipant(in: tfn, meetingID: self.configuration.meetingID)
        self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: self.generationNumber,
                                         remoteParticipant: remote, stage: .publishOffered)
        guard let receiveContext = self.receiveContext else {
            return self.rejectRemote(remote, reason: "receive context unavailable")
        }
        guard let remote else {
            return self.rejectRemote(nil, reason: "unexpected full track name")
        }
        guard remote != self.id else {
            return self.rejectRemote(remote, reason: "self publication")
        }
        guard self.configuration.participants.contains(remote), self.isParticipantEligible(remote) else {
            return self.rejectRemote(remote, reason: "participant unavailable")
        }
        let profile = Profile(qualityProfile: "h264,width=320,height=180,fps=30,br=400",
                              expiry: [5000, 5000], priorities: [2, 3],
                              namespace: components, name: "h264")
        let details = ManifestSubscription(mediaType: "video", sourceName: "synthetic",
                                           sourceID: "topn-\(remote.rawValue)-video", label: "Top-N synthetic video",
                                           participantId: ParticipantId(UInt32(self.configuration.participants.firstIndex(of: remote)! + 1)),
                                           profileSet: .init(type: "video", profiles: [profile]))
        let pubDetails = MoqCallController.PublisherInitiatedDetails(trackAlias: attributes.trackAlias,
                                                                     requestId: attributes.newGroupRequestId)
        if receiveContext.controller.getSubscriptionSet(details.sourceID) != nil {
            try? receiveContext.controller.unsubscribeToSet(details.sourceID)
        }
        let set = try? receiveContext.controller.subscribeToSet(details: details,
                                                                factory: receiveContext.subscriptionFactory,
                                                                subscribeType: .publisherInitiated(pubDetails))
        guard let set,
              let subscription = receiveContext.controller.getSubscriptions(set).last else {
            return self.rejectRemote(remote, reason: "subscription creation failed")
        }
        var response = attributes
        response.filterType = .latestObject
        response.forward = 1
        response.isPublisherInitiated = true
        self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: self.generationNumber,
                                         remoteParticipant: remote, stage: .publishAccepted)
        return .accept(response, subscription)
    }

    private func rejectRemote(_ remote: TopNParticipantID?, reason: String) -> PublishResponse {
        self.recorder.recordHarnessEvent(client: self.id, connectionGeneration: self.generationNumber,
                                         remoteParticipant: remote, stage: .publishRejected,
                                         details: .init(reason: reason))
        return .reject
    }

    nonisolated private static func remoteParticipant(in tfn: FullTrackName,
                                                      meetingID: String) -> TopNParticipantID? {
        let components = tfn.nameSpace.compactMap { String(data: $0, encoding: .utf8) }
        guard components.count == 4,
              components[0] == "meetings.wbx.com",
              components[1] == meetingID,
              components[2] == "video",
              String(data: tfn.name, encoding: .utf8) == "h264" else { return nil }
        return TopNParticipantID(rawValue: components[3])
    }
}

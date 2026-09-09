// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
import UIKit
import XCTest
@testable import QuicR

final class TestTopNHarnessOracle: XCTestCase {
    func testSimulreceiveQualitiesUseIndependentTopNNamespaces() {
        let qualities = TopNVideoQuality.allCases

        XCTAssertEqual(qualities.map(\.rawValue), ["1080p", "720p", "360p"])
        XCTAssertEqual(qualities.map { [$0.width, $0.height] },
                       [[1920, 1080], [1280, 720], [640, 360]])
        XCTAssertEqual(qualities.map(\.qualityProfile), [
            "h264,width=1920,height=1080,fps=30,br=4000",
            "h264,width=1280,height=720,fps=30,br=2000",
            "h264,width=640,height=360,fps=30,br=800"
        ])
        XCTAssertEqual(qualities.map { $0.subscribeNamespace(meetingID: "meeting") }, [
            ["meetings.wbx.com", "meeting", "video", "1080p"],
            ["meetings.wbx.com", "meeting", "video", "720p"],
            ["meetings.wbx.com", "meeting", "video", "360p"]
        ])
        XCTAssertEqual(qualities.map {
            $0.publicationNamespace(meetingID: "meeting", participant: .init(rawValue: "p1"))
        }, [
            ["meetings.wbx.com", "meeting", "video", "1080p", "p1"],
            ["meetings.wbx.com", "meeting", "video", "720p", "p1"],
            ["meetings.wbx.com", "meeting", "video", "360p", "p1"]
        ])
    }

    func testSimulreceiveFixtureRequiresAllThreeQualities() {
        let emptyVersionTwoContainer = Data([0x51, 0x54, 0x48, 0x31,
                                             0x00, 0x02, 0x00, 0x00])

        XCTAssertThrowsError(try TopNH264FixtureSet.load(data: emptyVersionTwoContainer)) { error in
            XCTAssertEqual(error as? TopNH264FixtureError,
                           .invalid("expected 3 quality fixtures, found 0"))
        }
    }

    func testSyntheticPublicationFactoryCreatesOneTrackPerQuality() throws {
        let participant = TopNParticipantID(rawValue: "p1")
        let fixtures = TopNH264FixtureSet(fixtures: Dictionary(uniqueKeysWithValues:
            TopNVideoQuality.allCases.map { quality in
                (quality, TopNH264Fixture(fps: 30, width: quality.width,
                                         height: quality.height, accessUnits: []))
            }))
        let profiles = TopNVideoQuality.allCases.map { quality in
            Profile(qualityProfile: quality.qualityProfile,
                    expiry: [5000, 5000], priorities: [2, 3],
                    namespace: quality.publicationNamespace(meetingID: "meeting", participant: participant),
                    name: "h264")
        }
        let recorder = TopNHarnessRecorder()
        let factory = SyntheticVideoPublicationFactory(
            fixtures: fixtures,
            startingGroupId: 1,
            startingRollReason: .initial,
            participant: participant,
            connectionGeneration: 1,
            faultController: .init(rules: [], recorder: recorder),
            onPublished: { _ in },
            onStatus: { _, _ in })
        let details = ManifestPublication(mediaType: "video", sourceName: "synthetic",
                                          sourceID: "topn-p1-video", label: "Top-N synthetic video",
                                          profileSet: .init(type: "video", profiles: profiles))

        let publications = try factory.create(publication: details, codecFactory: CodecFactoryImpl(),
                                              endpointId: "endpoint", relayId: "relay")

        XCTAssertEqual(publications.map { $0.0.nameSpace.compactMap { String(data: $0, encoding: .utf8) } }, [
            ["meetings.wbx.com", "meeting", "video", "1080p", "p1"],
            ["meetings.wbx.com", "meeting", "video", "720p", "p1"],
            ["meetings.wbx.com", "meeting", "video", "360p", "p1"]
        ])
        XCTAssertEqual(try factory.takeCreatedPublication().trackCount, 3)
    }

    func testDropNextIDRFaultAppliesToEveryQualityAtTheSameLocation() throws {
        let local = TopNParticipantID(rawValue: "p2")
        let remote = TopNParticipantID(rawValue: "p1")
        let rule = TopNFaultRule(id: "drop-idr", kind: .dropNextIDR,
                                 localParticipant: local, remoteParticipant: remote,
                                 connectionGeneration: 1, locationRange: nil,
                                 delaySeconds: nil, activity: nil, cached: nil)
        let controller = TopNHarnessFaultController(rules: [rule], recorder: .init())
        try controller.enable(id: rule.id)

        func ingress(_ quality: TopNVideoQuality, groupId: UInt64) throws -> VideoObjectIngress {
            .init(fullTrackName: try FullTrackName(
                namespace: quality.publicationNamespace(meetingID: "meeting", participant: remote),
                name: "h264"),
                groupId: groupId, subgroupId: 0, objectId: 0,
                payloadLength: 1, status: .available, activity: nil, cached: false)
        }
        func isDropped(_ decision: VideoObjectIngressDecision) -> Bool {
            if case .drop = decision { return true }
            return false
        }

        for quality in TopNVideoQuality.allCases {
            XCTAssertTrue(isDropped(controller.ingressDecision(
                localParticipant: local, remoteParticipant: remote, connectionGeneration: 1,
                ingress: try ingress(quality, groupId: 7))))
        }
        XCTAssertFalse(isDropped(controller.ingressDecision(
            localParticipant: local, remoteParticipant: remote, connectionGeneration: 1,
            ingress: try ingress(.p1080, groupId: 8))))
    }

    func testParticipantIdentifiersCannotEscapeArtifactDirectories() {
        XCTAssertTrue(TopNParticipantID(rawValue: "p1").isValidHarnessIdentifier)
        XCTAssertTrue(TopNParticipantID(rawValue: "p65535").isValidHarnessIdentifier)
        XCTAssertFalse(TopNParticipantID(rawValue: "../p1").isValidHarnessIdentifier)
        XCTAssertFalse(TopNParticipantID(rawValue: "p0").isValidHarnessIdentifier)
    }

    private func event(_ milliseconds: Double,
                       stage: TopNHarnessStage,
                       subscriber: TopNParticipantID,
                       publisher: TopNParticipantID,
                       connectionGeneration: UInt64 = 1,
                       generation: UInt64,
                       groupId: UInt64? = nil,
                       objectId: UInt64? = nil,
                       presentationSeconds: TimeInterval? = nil,
                       reason: String? = nil,
                       displayed: Bool? = nil,
                       quality: TopNVideoQuality? = nil) -> TopNHarnessRecordedEvent {
        .init(ordinal: UInt64(milliseconds), elapsedMilliseconds: milliseconds,
              wallClock: .distantPast, scheduledMilliseconds: nil,
              client: subscriber, connectionGeneration: connectionGeneration,
              remoteParticipant: publisher,
              handlerGeneration: generation, renderEpoch: 1,
              groupId: groupId, subgroupId: 0, objectId: objectId,
              stage: stage, activity: nil, actionID: nil,
              details: .init(reason: reason, displayed: displayed, quality: quality,
                             presentationSeconds: presentationSeconds))
    }

    func testSimulreceiveOracleRequiresThreeCandidatesAndHighestSelection() {
        let subscriber = TopNParticipantID(rawValue: "p2")
        let publisher = TopNParticipantID(rawValue: "p1")
        let candidates = TopNVideoQuality.allCases.enumerated().map { index, quality in
            self.event(Double(100 + index), stage: .simulreceiveCandidate,
                       subscriber: subscriber, publisher: publisher,
                       generation: UInt64(index + 1), presentationSeconds: 10, quality: quality)
        }
        let selected1080 = self.event(110, stage: .simulreceiveSelected,
                                      subscriber: subscriber, publisher: publisher,
                                      generation: 1, presentationSeconds: 10,
                                      displayed: true, quality: .p1080)
        let selected720 = self.event(110, stage: .simulreceiveSelected,
                                     subscriber: subscriber, publisher: publisher,
                                     generation: 2, presentationSeconds: 10,
                                     displayed: true, quality: .p720)

        XCTAssertNil(TopNHarnessOracle.simulreceiveViolation(in: candidates + [selected1080], since: 0))
        XCTAssertEqual(TopNHarnessOracle.simulreceiveViolation(
            in: Array(candidates.dropLast()) + [selected1080], since: 0), .simulreceiveNotExercised)
        XCTAssertEqual(TopNHarnessOracle.simulreceiveViolation(
            in: candidates + [selected720], since: 0), .lowerQualitySelected)

        let laterCandidates = TopNVideoQuality.allCases.enumerated().map { index, quality in
            self.event(Double(120 + index), stage: .simulreceiveCandidate,
                       subscriber: subscriber, publisher: publisher,
                       generation: UInt64(index + 1), presentationSeconds: 11, quality: quality)
        }
        let laterSelected720 = self.event(130, stage: .simulreceiveSelected,
                                          subscriber: subscriber, publisher: publisher,
                                          generation: 2, presentationSeconds: 11,
                                          displayed: true, quality: .p720)
        XCTAssertEqual(TopNHarnessOracle.simulreceiveViolation(
            in: candidates + [selected1080] + laterCandidates + [laterSelected720], since: 0),
            .lowerQualitySelected)
    }

    func testPipelineProgressRequiresOneOrderedCausalFrame() {
        let subscriber = TopNParticipantID(rawValue: "p2")
        let publisher = TopNParticipantID(rawValue: "p1")
        let events = [
            self.event(100, stage: .objectReceived, subscriber: subscriber, publisher: publisher,
                       generation: 1, groupId: 1, objectId: 4),
            self.event(110, stage: .objectUsable, subscriber: subscriber, publisher: publisher,
                       generation: 1, groupId: 1, objectId: 4, presentationSeconds: 10),
            self.event(120, stage: .decoderOutput, subscriber: subscriber, publisher: publisher,
                       generation: 1, presentationSeconds: 9),
            self.event(130, stage: .simulreceiveSelected, subscriber: subscriber, publisher: publisher,
                       generation: 1, presentationSeconds: 9, displayed: true),
            self.event(140, stage: .displayEnqueued, subscriber: subscriber, publisher: publisher,
                       generation: 1, presentationSeconds: 9)
        ]

        XCTAssertEqual(TopNHarnessOracle.missingRequiredStage(in: events, since: 0), .decoderOutput)
    }

    func testPipelineProgressCannotCrossConnectionGenerations() {
        let subscriber = TopNParticipantID(rawValue: "p2")
        let publisher = TopNParticipantID(rawValue: "p1")
        let events = [
            self.event(100, stage: .objectReceived, subscriber: subscriber, publisher: publisher,
                       connectionGeneration: 1, generation: 1, groupId: 1, objectId: 4),
            self.event(110, stage: .objectUsable, subscriber: subscriber, publisher: publisher,
                       connectionGeneration: 2, generation: 1, groupId: 1, objectId: 4,
                       presentationSeconds: 10),
            self.event(120, stage: .decoderOutput, subscriber: subscriber, publisher: publisher,
                       connectionGeneration: 2, generation: 1, presentationSeconds: 10),
            self.event(130, stage: .simulreceiveSelected, subscriber: subscriber, publisher: publisher,
                       connectionGeneration: 2, generation: 1, presentationSeconds: 10, displayed: true),
            self.event(140, stage: .displayEnqueued, subscriber: subscriber, publisher: publisher,
                       connectionGeneration: 2, generation: 1, presentationSeconds: 10)
        ]

        XCTAssertEqual(TopNHarnessOracle.missingRequiredStage(in: events, since: 0), .objectUsable)
    }

    func testTieRequiresTheExpectedNumberOfDeliveredTracks() {
        let p1 = TopNParticipantID(rawValue: "p1")
        let p2 = TopNParticipantID(rawValue: "p2")
        let p3 = TopNParticipantID(rawValue: "p3")
        let online: Set<TopNParticipantID> = [p1, p2, p3]
        let view = TopNHarnessOracle.resolve(subscriber: p3,
                                             activity: [p1: .speechStart, p2: .speechStart, p3: .speechEnd],
                                             online: online, topN: 1)

        XCTAssertEqual(TopNHarnessOracle.deliveryViolations(subscriber: p3, view: view,
                                                            online: online, delivered: []).map(\.code),
                       [.tooFewDelivered])
        XCTAssertEqual(Set(TopNHarnessOracle.deliveryViolations(subscriber: p3, view: view,
                                                                online: online, delivered: [p1, p2]).map(\.code)),
                       [.tooManyDelivered])
    }

    func testExpectedViewAndPipelineOracle() {
        let p1 = TopNParticipantID(rawValue: "p1")
        let p2 = TopNParticipantID(rawValue: "p2")
        let p3 = TopNParticipantID(rawValue: "p3")
        let online: Set<TopNParticipantID> = [p1, p2, p3]
        let complete: [Ticks] = [10, 20, 30]
        let completeProgress = TopNStageProgress(received: complete,
                                                 usable: complete,
                                                 decoded: complete,
                                                 selected: complete,
                                                 displayed: complete)
        var receiptOnlyProgress = TopNStageProgress()
        receiptOnlyProgress.received = [10]
        struct Row {
            let name: String
            let subscriber: TopNParticipantID
            let activity: [TopNParticipantID: TopNActivity]
            let online: Set<TopNParticipantID>
            let delivered: Set<TopNParticipantID>
            let progress: [TopNParticipantID: TopNStageProgress]
            let violations: Set<TopNOracleViolation.Code>
        }
        let rows: [Row] = [
            .init(name: "unique", subscriber: p3,
                  activity: [p1: .speechStart, p2: .speechEnd, p3: .speechEnd], online: online,
                  delivered: [p1], progress: [p1: completeProgress], violations: []),
            .init(name: "self", subscriber: p3,
                  activity: [p1: .continuousSpeech, p2: .speechEnd, p3: .speechStart], online: online,
                  delivered: [p1, p3], progress: [p1: completeProgress], violations: [.selfDelivery]),
            .init(name: "offline", subscriber: p3,
                  activity: [p1: .speechStart, p2: .continuousSpeech, p3: .speechEnd], online: [p3],
                  delivered: [p1], progress: [:], violations: [.offlineDelivery]),
            .init(name: "tie", subscriber: p3,
                  activity: [p1: .speechStart, p2: .speechStart, p3: .speechEnd], online: online,
                  delivered: [p1], progress: [p1: completeProgress], violations: []),
            .init(name: "only-receipt", subscriber: p3,
                  activity: [p1: .speechStart, p2: .speechEnd, p3: .speechEnd], online: online,
                  delivered: [p1], progress: [p1: receiptOnlyProgress],
                  violations: [.noUsableObject, .noDecoderOutput, .noSelection, .noDisplay,
                               .displayNotSustained])
        ]

        for row in rows {
            let view = TopNHarnessOracle.resolve(subscriber: row.subscriber, activity: row.activity,
                                                 online: row.online, topN: 1)
            let violations = TopNHarnessOracle.evaluate(subscriber: row.subscriber, view: view,
                                                        online: row.online, connectionHealthy: true,
                                                        delivered: row.delivered, progress: row.progress,
                                                        stageWindowStart: 0, livenessWindowStart: 10,
                                                        now: 30, maxDisplayGapSeconds: 1)
            XCTAssertEqual(Set(violations.map(\.code)), row.violations, row.name)
        }
    }

    func testLifecycleReactivationRequiresCleanupAndFreshSustainedPipeline() {
        let subscriber = TopNParticipantID(rawValue: "p2")
        let publisher = TopNParticipantID(rawValue: "p1")
        let complete = [
            self.event(100, stage: .handlerStopped, subscriber: subscriber, publisher: publisher,
                       generation: 1, reason: VideoHandlerStopReason.inactiveCleanup.rawValue),
            self.event(200, stage: .handlerCreated, subscriber: subscriber, publisher: publisher,
                       generation: 2, reason: ActivationType.reactivation.rawValue),
            self.event(210, stage: .objectReceived, subscriber: subscriber, publisher: publisher,
                       generation: 2, groupId: 1, objectId: 1),
            self.event(220, stage: .objectUsable, subscriber: subscriber, publisher: publisher,
                       generation: 2, groupId: 1, objectId: 1, presentationSeconds: 10),
            self.event(230, stage: .decoderOutput, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10),
            self.event(240, stage: .simulreceiveSelected, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10, displayed: true),
            self.event(250, stage: .displayEnqueued, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10),
            self.event(260, stage: .displayPresented, subscriber: subscriber, publisher: publisher, generation: 2),
            self.event(700, stage: .displayEnqueued, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10)
        ]

        XCTAssertNil(TopNHarnessOracle.lifecycleReactivationFailure(
                        in: complete, subscriber: subscriber, publisher: publisher,
                        inactiveSinceMilliseconds: 0, activeSinceMilliseconds: 180,
                        nowMilliseconds: 900, maxDisplayGapMilliseconds: 750))
        XCTAssertEqual(TopNHarnessOracle.lifecycleReactivationFailure(
                        in: Array(complete.dropFirst()), subscriber: subscriber, publisher: publisher,
                        inactiveSinceMilliseconds: 0, activeSinceMilliseconds: 180,
                        nowMilliseconds: 900, maxDisplayGapMilliseconds: 750), .missingInactiveCleanup)
        XCTAssertEqual(TopNHarnessOracle.lifecycleReactivationFailure(
                        in: complete.filter { $0.stage != .displayPresented },
                        subscriber: subscriber, publisher: publisher,
                        inactiveSinceMilliseconds: 0, activeSinceMilliseconds: 180,
                        nowMilliseconds: 900, maxDisplayGapMilliseconds: 750), .noPresentedFrame)
    }

    func testLifecycleReactivationRejectsStaleGenerationDisplay() {
        let subscriber = TopNParticipantID(rawValue: "p2")
        let publisher = TopNParticipantID(rawValue: "p1")
        var events = [
            self.event(100, stage: .handlerStopped, subscriber: subscriber, publisher: publisher,
                       generation: 1, reason: VideoHandlerStopReason.inactiveCleanup.rawValue),
            self.event(200, stage: .handlerCreated, subscriber: subscriber, publisher: publisher,
                       generation: 2, reason: ActivationType.reactivation.rawValue),
            self.event(210, stage: .objectReceived, subscriber: subscriber, publisher: publisher,
                       generation: 2, groupId: 1, objectId: 1),
            self.event(220, stage: .objectUsable, subscriber: subscriber, publisher: publisher,
                       generation: 2, groupId: 1, objectId: 1, presentationSeconds: 10),
            self.event(230, stage: .decoderOutput, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10),
            self.event(240, stage: .simulreceiveSelected, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10, displayed: true),
            self.event(250, stage: .displayEnqueued, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10),
            self.event(700, stage: .displayEnqueued, subscriber: subscriber, publisher: publisher,
                       generation: 2, presentationSeconds: 10)
        ]
        events.append(self.event(300, stage: .displayEnqueued, subscriber: subscriber,
                                 publisher: publisher, generation: 1, presentationSeconds: 9))

        XCTAssertEqual(TopNHarnessOracle.lifecycleReactivationFailure(
                        in: events, subscriber: subscriber, publisher: publisher,
                        inactiveSinceMilliseconds: 0, activeSinceMilliseconds: 180,
                        nowMilliseconds: 900, maxDisplayGapMilliseconds: 750), .staleGenerationDisplay)
    }

    func testLifecycleConversationIsSeededAndForcesCleanupWindows() throws {
        let participants = ["p1", "p2", "p3"].map(TopNParticipantID.init(rawValue:))
        let selection = try TopNScenarioSelection(kind: .lifecycleConversation,
                                                  builtIn: nil, seed: 41,
                                                  durationMilliseconds: 30_000,
                                                  replayPath: nil).validated()
        let scenario = try TopNScenarioResolver().resolve(selection: selection, participants: participants)
        let replay = try TopNScenarioResolver().resolve(selection: selection, participants: participants)

        XCTAssertEqual(scenario.name, "lifecycle-conversation")
        XCTAssertEqual(scenario.seed, 41)
        XCTAssertEqual(scenario.actions.map(\.id), replay.actions.map(\.id))
        let lifecycleChecks = scenario.actions.filter {
            $0.kind == .checkpoint && $0.name?.hasPrefix("lifecycle-reactivation:") == true
        }
        XCTAssertGreaterThan(lifecycleChecks.count, 2)
        for checkpoint in lifecycleChecks {
            let components = try XCTUnwrap(checkpoint.name).split(separator: ":")
            let publisher = TopNParticipantID(rawValue: String(components[1]))
            let activation = try XCTUnwrap(scenario.actions.last(where: {
                $0.kind == .activity && $0.participant == publisher &&
                    $0.activity == .speechStart && $0.atMilliseconds < checkpoint.atMilliseconds
            }))
            let inactive = try XCTUnwrap(scenario.actions.last(where: {
                $0.kind == .activity && $0.participant == publisher &&
                    $0.activity == .speechEnd && $0.atMilliseconds < activation.atMilliseconds
            }))
            XCTAssertGreaterThanOrEqual(activation.atMilliseconds - inactive.atMilliseconds, 4_000)
        }
    }

    func testLifecycleConversationActionsRemainOrderedWithLongOverlaps() throws {
        let participants = ["p1", "p2", "p3"].map(TopNParticipantID.init(rawValue:))
        let selection = TopNScenarioSelection(kind: .lifecycleConversation,
                                              builtIn: nil, seed: 1_704,
                                              durationMilliseconds: 500_000,
                                              replayPath: nil)
        let scenario = try TopNScenarioResolver().resolve(selection: selection, participants: participants)

        XCTAssertTrue(zip(scenario.actions, scenario.actions.dropFirst()).allSatisfy {
            $0.atMilliseconds <= $1.atMilliseconds
        })
        XCTAssertEqual(scenario.actions.last?.atMilliseconds, 500_000)
    }

    func testPresentationPixelCheckRejectsBlackAndAcceptsVisibleLuma() {
        XCTAssertFalse(TopNHarnessPresentation.isVisiblyNonBlack(luma: [0, 0, 16, 16, 16]))
        XCTAssertTrue(TopNHarnessPresentation.isVisiblyNonBlack(luma: [16, 16, 64, 128, 220]))
    }

    func testPresentationRetryPolicyAllowsOnlyTransientViewConvergenceErrors() {
        XCTAssertTrue(TopNHarnessPresentationError.invalidLayer.isRetryableBeforeDeadline)
        XCTAssertTrue(TopNHarnessPresentationError.timebase("missing").isRetryableBeforeDeadline)
        XCTAssertTrue(TopNHarnessPresentationError.noDisplayedPixelBuffer.isRetryableBeforeDeadline)
        XCTAssertTrue(TopNHarnessPresentationError.blackFrame.isRetryableBeforeDeadline)
        XCTAssertFalse(TopNHarnessPresentationError.noWindowScene.isRetryableBeforeDeadline)
        XCTAssertFalse(TopNHarnessPresentationError.layerFailed.isRetryableBeforeDeadline)
    }

    func testPresentationPixelCheckHandles24BitRGBRows() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                           kCMPixelFormat_24RGB, nil, &pixelBuffer), kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: CVPixelBufferGetDataSize(image), by: 3) {
                bytes[offset] = 96
                bytes[offset + 1] = 64
                bytes[offset + 2] = 32
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])

        let samples = TopNHarnessPresentation.lumaSamples(from: image)

        XCTAssertEqual(samples.count, 1_024)
        XCTAssertEqual(Set(samples).count, 1)
        XCTAssertTrue(TopNHarnessPresentation.isVisiblyNonBlack(luma: samples))
    }

    func testPresentationPixelCheckConvertsUnsupportedPackedFormats() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                           kCVPixelFormatType_64RGBAHalf, nil, &pixelBuffer), kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            let bytes = base.assumingMemoryBound(to: UInt16.self)
            for y in 0 ..< CVPixelBufferGetHeight(image) {
                let row = bytes.advanced(by: y * CVPixelBufferGetBytesPerRow(image) / MemoryLayout<UInt16>.size)
                for x in 0 ..< CVPixelBufferGetWidth(image) {
                    let offset = x * 4
                    row[offset] = Float16(0.375).bitPattern
                    row[offset + 1] = Float16(0.25).bitPattern
                    row[offset + 2] = Float16(0.125).bitPattern
                    row[offset + 3] = Float16(1).bitPattern
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])

        let samples = TopNHarnessPresentation.lumaSamples(from: image)

        XCTAssertEqual(samples.count, 1_024)
        XCTAssertEqual(Set(samples).count, 1)
        XCTAssertTrue(TopNHarnessPresentation.isVisiblyNonBlack(luma: samples))
    }

    @MainActor
    func testPresentationPixelCheckHandlesRenderedImages() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor(red: 0.5, green: 0.25, blue: 0.125, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let samples = TopNHarnessPresentation.lumaSamples(from: try XCTUnwrap(image.cgImage))

        XCTAssertEqual(samples.count, 1_024)
        XCTAssertTrue(TopNHarnessPresentation.isVisiblyNonBlack(luma: samples))
    }

    @MainActor
    func testPresentationHostRejectsLayerWithoutPresentedFrame() async {
        do {
            let videoView = VideoView()
            let host = try TopNHarnessPresentationHost()
            host.attach(videoView)
            _ = try await host.capture(videoView, timeout: .milliseconds(50))
            XCTFail("Expected an empty display layer to have no presented pixel buffer")
        } catch let error as TopNHarnessPresentationError {
            XCTAssertEqual(error, .noDisplayedPixelBuffer)
        } catch {
            XCTFail("Unexpected presentation error: \(error)")
        }
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
import UIKit
import XCTest
@testable import QuicR

final class TestTopNHarnessOracle: XCTestCase {
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
                       displayed: Bool? = nil) -> TopNHarnessRecordedEvent {
        .init(ordinal: UInt64(milliseconds), elapsedMilliseconds: milliseconds,
              wallClock: .distantPast, scheduledMilliseconds: nil,
              client: subscriber, connectionGeneration: connectionGeneration,
              remoteParticipant: publisher,
              handlerGeneration: generation, renderEpoch: 1,
              groupId: groupId, subgroupId: 0, objectId: objectId,
              stage: stage, activity: nil, actionID: nil,
              details: .init(reason: reason, displayed: displayed,
                             presentationSeconds: presentationSeconds))
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

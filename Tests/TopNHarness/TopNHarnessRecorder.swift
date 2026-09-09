// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization
@testable import QuicR

final class TopNHarnessRecorder: @unchecked Sendable {
    private struct State {
        var nextOrdinal: UInt64 = 0
        var events: [TopNHarnessRecordedEvent] = []
    }

    private let startTicks: Ticks
    private let startWallClock: Date
    private let state = Mutex(State())

    init(startTicks: Ticks = .now, startWallClock: Date = .now) {
        self.startTicks = startTicks
        self.startWallClock = startWallClock
    }

    func record(client: TopNParticipantID,
                connectionGeneration: UInt64,
                event: VideoPipelineEvent,
                scheduledMilliseconds: Double? = nil,
                remoteParticipant: TopNParticipantID? = nil,
                actionID: String? = nil) {
        let elapsed = event.occurredAt.timeIntervalSince(self.startTicks)
        let wallClock = self.startWallClock.addingTimeInterval(elapsed)
        let stage = event.kind.topNStage
        let activity = Self.activity(from: event.kind)
        let remoteTrack = Self.remoteTrack(from: event.fullTrackName)
        let details = Self.details(from: event.kind, quality: remoteTrack?.quality)
        let observedRemoteParticipant = remoteParticipant ?? remoteTrack?.participant
        self.state.withLock { state in
            state.nextOrdinal += 1
            let recorded = TopNHarnessRecordedEvent(
                ordinal: state.nextOrdinal, elapsedMilliseconds: elapsed * 1000,
                wallClock: wallClock, scheduledMilliseconds: scheduledMilliseconds,
                client: client, connectionGeneration: connectionGeneration,
                remoteParticipant: observedRemoteParticipant,
                handlerGeneration: event.handlerGeneration, renderEpoch: event.renderEpoch,
                groupId: event.groupId, subgroupId: event.subgroupId, objectId: event.objectId,
                stage: stage, activity: activity, actionID: actionID, details: details)
            state.events.append(recorded)
        }
    }

    func videoCallback(client: TopNParticipantID,
                       connectionGeneration: UInt64) -> VideoPipelineEventCallback {
        { [weak self] event in
            self?.record(client: client, connectionGeneration: connectionGeneration, event: event)
        }
    }

    func recordHarnessEvent(client: TopNParticipantID,
                            connectionGeneration: UInt64,
                            remoteParticipant: TopNParticipantID? = nil,
                            groupId: UInt64? = nil,
                            subgroupId: UInt64? = nil,
                            objectId: UInt64? = nil,
                            scheduledMilliseconds: Double? = nil,
                            actionID: String? = nil,
                            handlerGeneration: UInt64? = nil,
                            stage: TopNHarnessStage,
                            details: TopNHarnessEventDetails? = nil) {
        let now = Ticks.now
        let elapsed = now.timeIntervalSince(self.startTicks)
        let wallClock = self.startWallClock.addingTimeInterval(elapsed)
        self.state.withLock { state in
            state.nextOrdinal += 1
            state.events.append(.init(ordinal: state.nextOrdinal,
                                      elapsedMilliseconds: elapsed * 1000,
                                      wallClock: wallClock,
                                      scheduledMilliseconds: scheduledMilliseconds,
                                      client: client,
                                      connectionGeneration: connectionGeneration,
                                      remoteParticipant: remoteParticipant,
                                      handlerGeneration: handlerGeneration,
                                      renderEpoch: nil,
                                      groupId: groupId,
                                      subgroupId: subgroupId,
                                      objectId: objectId,
                                      stage: stage,
                                      activity: nil,
                                      actionID: actionID,
                                      details: details))
        }
    }

    func snapshot() -> [TopNHarnessRecordedEvent] {
        self.state.withLock { $0.events }
    }

    func flushEvents(to url: URL) throws {
        let events = self.snapshot()
        let encoder = Self.encoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    func writeSummary(_ summary: TopNHarnessSummary, to url: URL) throws {
        var data = try Self.encoder().encode(summary)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func activity(from kind: VideoPipelineEvent.Kind) -> UInt8? {
        guard case .objectReceived(_, let activity) = kind else { return nil }
        return activity
    }

    private static func details(from kind: VideoPipelineEvent.Kind,
                                quality: TopNVideoQuality?) -> TopNHarnessEventDetails? {
        switch kind {
        case .subscriptionStatus(let status): return .init(status: status)
        case .objectReceived(let cached, _): return .init(cached: cached)
        case .objectRejected(let reason, let detail): return .init(reason: detail ?? reason.rawValue)
        case .handlerCreated(let activation): return .init(reason: activation.rawValue)
        case .handlerStopped(let reason): return .init(reason: reason.rawValue)
        case .joinDecision(let strategy): return .init(joinStrategy: strategy.rawValue)
        case .fetchRequested(let start, let end): return .init(startObjectId: start, endObjectId: end)
        case .fetchStatus(let status): return .init(status: status)
        case .jitterRejected(let reason): return .init(reason: reason.rawValue)
        case .jitterDequeued(let timing):
            return .init(scheduledWaitSeconds: timing.scheduledWaitSeconds,
                         deadlineLatenessSeconds: timing.deadlineLatenessSeconds,
                         bufferDepthSeconds: timing.bufferDepthSeconds,
                         resumedFromEmpty: timing.resumedFromEmpty)
        case .nameGate(let accepted, let previousGroup, let previousObject):
            return .init(accepted: accepted, previousGroupId: previousGroup, previousObjectId: previousObject)
        case .objectUsable(let seconds), .decoderSubmitted(let seconds),
             .decoderOutput(let seconds), .displayEnqueued(let seconds):
            return .init(presentationSeconds: seconds)
        case .simulreceiveCandidate(let seconds):
            return .init(quality: quality, presentationSeconds: seconds)
        case .decoderError(let error), .displayError(let error): return .init(reason: error)
        case .simulreceiveSelected(let displayed, let seconds):
            return .init(displayed: displayed, quality: quality, presentationSeconds: seconds)
        case .displayEnqueueTiming(let timing):
            return .init(presentationSeconds: timing.presentationSeconds,
                         frameAgeSeconds: timing.frameAgeSeconds,
                         mainActorQueueDelaySeconds: timing.mainActorQueueDelaySeconds,
                         scheduledPresentationLeadSeconds: timing.scheduledPresentationLeadSeconds,
                         displayImmediately: timing.displayImmediately,
                         readyForMoreMediaData: timing.readyForMoreMediaData)
        default: return nil
        }
    }

    private static func remoteTrack(from fullTrackName: FullTrackName) ->
        (participant: TopNParticipantID, quality: TopNVideoQuality)? {
        let components = fullTrackName.nameSpace.compactMap { String(data: $0, encoding: .utf8) }
        guard components.count == 5, components[0] == "meetings.wbx.com",
              components[2] == "video",
              let quality = TopNVideoQuality(rawValue: components[3]),
              String(data: fullTrackName.name, encoding: .utf8) == "h264" else { return nil }
        return (TopNParticipantID(rawValue: components[4]), quality)
    }
}

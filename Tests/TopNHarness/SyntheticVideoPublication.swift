// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization
@testable import QuicR

enum TopNGroupRollReason: String, Codable, Sendable {
    case initial
    case naturalGOP
    case activityRise
    case newGroupRequest
    case reconnect
    case injectedReuse
    case injectedRegression
}

struct TopNPublishedObject: Sendable {
    let fullTrackName: FullTrackName
    let groupId: UInt64
    let subgroupId: UInt64
    let objectId: UInt64
    let fixtureIndex: Int
    let activity: TopNActivity
    let activityActionID: String?
    let rollReason: TopNGroupRollReason?
    let status: QPublishObjectStatus
    let at: Ticks
}

final class SyntheticVideoPublicationTrack: PublicationInstance, @unchecked Sendable {
    let quality: TopNVideoQuality
    let profile: Profile
    let sink: MoQSink
    private let statusHandler = Mutex<(@Sendable (QPublishTrackHandlerStatus) -> Void)?>(nil)

    init(quality: TopNVideoQuality, profile: Profile, sink: MoQSink) {
        self.quality = quality
        self.profile = profile
        self.sink = sink
        self.sink.setCallbacks(onStatus: { [weak self] status in
            self?.statusHandler.withLock { $0?(status) }
        }, onMetrics: { _ in })
    }

    func setStatusHandler(_ handler: @escaping @Sendable (QPublishTrackHandlerStatus) -> Void) {
        self.statusHandler.withLock { $0 = handler }
    }
}

final class SyntheticVideoPublication: @unchecked Sendable {
    private struct ControlState: Sendable {
        var activity: TopNActivity = .speechEnd
        var actionID: String?
        var requestedNGRGeneration: UInt64 = 0
        var lastSuccessfulGroupId: UInt64?
    }

    private struct Candidate: Sendable {
        let groupId: UInt64
        let subgroupId: UInt64
        let objectId: UInt64
        let fixtureIndex: Int
        let activity: TopNActivity
        let actionID: String?
        let rollReason: TopNGroupRollReason?
        let closeGroupId: UInt64?
        let closeSubgroupId: UInt64?
        let transition: VideoVADTransition
        let handledNGRGeneration: UInt64
        let captureTimestamp: Date
        let publishTimestamp: Date
        var remainingQualities: Set<TopNVideoQuality>
        var closedQualities: Set<TopNVideoQuality>
    }

    private let fixtures: TopNH264FixtureSet
    private let tracks: [TopNVideoQuality: SyntheticVideoPublicationTrack]
    private let startingGroupId: UInt64
    private let startingRollReason: TopNGroupRollReason
    private let participant: TopNParticipantID
    private let connectionGeneration: UInt64
    private let faultController: TopNHarnessFaultController
    private let onPublished: @Sendable (TopNPublishedObject) -> Void
    private let onStatus: @Sendable (TopNVideoQuality, QPublishTrackHandlerStatus) -> Void
    private let control = Mutex(ControlState())
    private var mediaTask: Task<Void, Never>?

    var trackCount: Int { self.tracks.count }

    init(fixtures: TopNH264FixtureSet,
         tracks: [SyntheticVideoPublicationTrack],
         startingGroupId: UInt64,
         startingRollReason: TopNGroupRollReason,
         participant: TopNParticipantID,
         connectionGeneration: UInt64,
         faultController: TopNHarnessFaultController,
         onPublished: @escaping @Sendable (TopNPublishedObject) -> Void,
         onStatus: @escaping @Sendable (TopNVideoQuality, QPublishTrackHandlerStatus) -> Void) {
        self.fixtures = fixtures
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.quality, $0) })
        self.startingGroupId = startingGroupId
        self.startingRollReason = startingRollReason
        self.participant = participant
        self.connectionGeneration = connectionGeneration
        self.faultController = faultController
        self.onPublished = onPublished
        self.onStatus = onStatus
        for track in tracks {
            track.setStatusHandler { [weak self] status in
                self?.handleStatus(status, quality: track.quality)
            }
        }
    }

    @MainActor
    func start() {
        guard self.mediaTask == nil else { return }
        self.mediaTask = Task { [self] in
            await self.run()
        }
    }

    @MainActor
    func stop() async {
        guard let task = self.mediaTask else { return }
        self.mediaTask = nil
        task.cancel()
        await task.value
    }

    func setActivity(_ activity: TopNActivity, actionID: String) {
        self.control.withLock {
            $0.activity = activity
            $0.actionID = actionID
        }
    }

    var lastSuccessfulGroupId: UInt64? {
        self.control.withLock { $0.lastSuccessfulGroupId }
    }

    private func handleStatus(_ status: QPublishTrackHandlerStatus, quality: TopNVideoQuality) {
        if quality == .p1080, status == .newGroupRequested {
            let suppressed = self.faultController.shouldSuppressNextNGR(
                publisher: self.participant, connectionGeneration: self.connectionGeneration)
            if !suppressed {
                self.control.withLock { state in
                    guard state.requestedNGRGeneration < .max else { return }
                    state.requestedNGRGeneration += 1
                }
            }
        }
        self.onStatus(quality, status)
    }

    private func makeFirstCandidate(groupId: UInt64,
                                    transition: VideoVADTransition) -> Candidate {
        let snapshot = self.control.withLock { $0 }
        var nextTransition = transition
        _ = nextTransition.update(.init(rawValue: snapshot.activity.rawValue) ?? .speechEnd)
        return .init(groupId: groupId, subgroupId: 0, objectId: 0, fixtureIndex: 0,
                     activity: snapshot.activity, actionID: snapshot.actionID,
                     rollReason: self.startingRollReason, closeGroupId: nil, closeSubgroupId: nil,
                     transition: nextTransition, handledNGRGeneration: snapshot.requestedNGRGeneration,
                     captureTimestamp: .now, publishTimestamp: .now,
                     remainingQualities: Set(TopNVideoQuality.allCases), closedQualities: [])
    }

    private func makeNextCandidate(groupId: UInt64, subgroupId: UInt64, objectId: UInt64,
                                   fixtureIndex: Int, subgroupOpen: Bool,
                                   transition: VideoVADTransition,
                                   handledNGRGeneration: UInt64) -> Candidate {
        let snapshot = self.control.withLock { $0 }
        var nextTransition = transition
        let activityResult = nextTransition.update(.init(rawValue: snapshot.activity.rawValue) ?? .speechEnd)
        let naturalRoll = fixtureIndex >= self.fixtures[.p1080].accessUnits.count
        let ngr = snapshot.requestedNGRGeneration > handledNGRGeneration
        let reason: TopNGroupRollReason? = if ngr {
            .newGroupRequest
        } else if activityResult.rollGroup {
            .activityRise
        } else if naturalRoll {
            .naturalGOP
        } else {
            nil
        }
        let rollsGroup = reason != nil
        let rollsSubgroup = !rollsGroup && activityResult.rollSubgroup
        return .init(groupId: rollsGroup ? groupId + 1 : groupId,
                     subgroupId: rollsGroup ? 0 : (rollsSubgroup ? subgroupId + 1 : subgroupId),
                     objectId: rollsGroup ? 0 : objectId,
                     fixtureIndex: rollsGroup ? 0 : fixtureIndex,
                     activity: snapshot.activity, actionID: snapshot.actionID,
                     rollReason: reason,
                     closeGroupId: (rollsGroup || rollsSubgroup) && subgroupOpen ? groupId : nil,
                     closeSubgroupId: (rollsGroup || rollsSubgroup) && subgroupOpen ? subgroupId : nil,
                     transition: nextTransition,
                     handledNGRGeneration: ngr ? snapshot.requestedNGRGeneration : handledNGRGeneration,
                     captureTimestamp: .now, publishTimestamp: .now,
                     remainingQualities: Set(TopNVideoQuality.allCases), closedQualities: [])
    }

    private func publish(_ candidate: inout Candidate) {
        for quality in TopNVideoQuality.allCases where candidate.remainingQualities.contains(quality) {
            guard let track = self.tracks[quality], track.sink.canPublish else { continue }
            if let closeGroupId = candidate.closeGroupId,
               let closeSubgroupId = candidate.closeSubgroupId,
               !candidate.closedQualities.contains(quality) {
                track.sink.endSubgroup(groupId: closeGroupId, subgroupId: closeSubgroupId, completed: true)
                candidate.closedQualities.insert(quality)
            }
            let frame = self.fixtures[quality].accessUnits[candidate.fixtureIndex]
            do {
                var extensions = HeaderExtensions()
                try extensions.setHeader(.captureTimestamp(candidate.captureTimestamp))
                try extensions.setHeader(.audioActivityIndicator(candidate.activity.rawValue))
                try extensions.setHeader(.publishTimestamp(candidate.publishTimestamp))
                var priority = try track.profile.getPriority(index: frame.isIDR ? 0 : 1)
                var ttl = try track.profile.getTTL(index: frame.isIDR ? 0 : 1)
                let status = withUnsafePointer(to: &priority) { priorityPointer in
                    withUnsafePointer(to: &ttl) { ttlPointer in
                        track.sink.publishObject(
                            QObjectHeaders(groupId: candidate.groupId, subgroupId: candidate.subgroupId,
                                           objectId: candidate.objectId, payloadLength: UInt64(frame.payload.count),
                                           status: .available, priority: priorityPointer, ttl: ttlPointer),
                            data: frame.payload, extensions: extensions,
                            immutableExtensions: nil, streamHeaderProperties: nil)
                    }
                }
                self.onPublished(.init(fullTrackName: track.sink.fullTrackName,
                                       groupId: candidate.groupId, subgroupId: candidate.subgroupId,
                                       objectId: candidate.objectId, fixtureIndex: candidate.fixtureIndex,
                                       activity: candidate.activity, activityActionID: candidate.actionID,
                                       rollReason: candidate.rollReason, status: status, at: .now))
                if status == .ok {
                    candidate.remainingQualities.remove(quality)
                }
            } catch {
                continue
            }
        }
    }

    private func run() async {
        let clock = ContinuousClock()
        let interval = Duration.seconds(1.0 / 30.0)
        var deadline = clock.now
        var groupId = self.startingGroupId
        var subgroupId: UInt64 = 0
        var objectId: UInt64 = 0
        var fixtureIndex = 0
        var transition = VideoVADTransition()
        var handledNGRGeneration: UInt64 = 0
        var subgroupOpen = false
        var pendingCandidate: Candidate?
        var firstCandidate = true

        defer {
            if subgroupOpen {
                for track in self.tracks.values {
                    track.sink.endSubgroup(groupId: groupId, subgroupId: subgroupId, completed: true)
                }
            }
        }

        while !Task.isCancelled {
            if pendingCandidate == nil {
                if firstCandidate {
                    pendingCandidate = self.makeFirstCandidate(groupId: groupId, transition: transition)
                    firstCandidate = false
                } else {
                    pendingCandidate = self.makeNextCandidate(
                        groupId: groupId, subgroupId: subgroupId, objectId: objectId,
                        fixtureIndex: fixtureIndex, subgroupOpen: subgroupOpen,
                        transition: transition, handledNGRGeneration: handledNGRGeneration)
                }
            }

            if var candidate = pendingCandidate {
                self.publish(&candidate)
                if candidate.remainingQualities.isEmpty {
                    groupId = candidate.groupId
                    subgroupId = candidate.subgroupId
                    objectId = candidate.objectId + 1
                    fixtureIndex = candidate.fixtureIndex + 1
                    transition = candidate.transition
                    handledNGRGeneration = candidate.handledNGRGeneration
                    subgroupOpen = true
                    self.control.withLock {
                        $0.lastSuccessfulGroupId = groupId
                        $0.actionID = nil
                    }
                    pendingCandidate = nil
                } else {
                    pendingCandidate = candidate
                }
            }
            deadline += interval
            do {
                try await clock.sleep(until: deadline)
            } catch {
                break
            }
        }
    }
}

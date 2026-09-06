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

final class SyntheticVideoPublication: PublicationInstance, @unchecked Sendable {
    let sink: MoQSink

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
    }

    private let profile: Profile
    private let fixture: TopNH264Fixture
    private let startingGroupId: UInt64
    private let startingRollReason: TopNGroupRollReason
    private let participant: TopNParticipantID
    private let connectionGeneration: UInt64
    private let faultController: TopNHarnessFaultController
    private let onPublished: @Sendable (TopNPublishedObject) -> Void
    private let onStatus: @Sendable (QPublishTrackHandlerStatus) -> Void
    private let control = Mutex(ControlState())
    private var mediaTask: Task<Void, Never>?

    init(profile: Profile,
         fixture: TopNH264Fixture,
         startingGroupId: UInt64,
         startingRollReason: TopNGroupRollReason,
         participant: TopNParticipantID,
         connectionGeneration: UInt64,
         faultController: TopNHarnessFaultController,
         onPublished: @escaping @Sendable (TopNPublishedObject) -> Void,
         onStatus: @escaping @Sendable (QPublishTrackHandlerStatus) -> Void,
         sink: MoQSink) {
        self.profile = profile
        self.fixture = fixture
        self.startingGroupId = startingGroupId
        self.startingRollReason = startingRollReason
        self.participant = participant
        self.connectionGeneration = connectionGeneration
        self.faultController = faultController
        self.onPublished = onPublished
        self.onStatus = onStatus
        self.sink = sink
        self.sink.setCallbacks(onStatus: { [weak self] status in
            self?.handleStatus(status)
        }, onMetrics: { _ in })
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

    private func handleStatus(_ status: QPublishTrackHandlerStatus) {
        if status == .newGroupRequested {
            let suppressed = self.faultController.shouldSuppressNextNGR(
                publisher: self.participant, connectionGeneration: self.connectionGeneration)
            if !suppressed {
                self.control.withLock { state in
                    guard state.requestedNGRGeneration < .max else { return }
                    state.requestedNGRGeneration += 1
                }
            }
        }
        self.onStatus(status)
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
                self.sink.endSubgroup(groupId: groupId, subgroupId: subgroupId, completed: true)
            }
        }

        while !Task.isCancelled {
            if self.sink.canPublish, pendingCandidate == nil {
                let snapshot = self.control.withLock { $0 }
                var nextTransition = transition
                let activityResult = nextTransition.update(.init(rawValue: snapshot.activity.rawValue) ?? .speechEnd)
                if firstCandidate {
                    pendingCandidate = .init(groupId: groupId,
                                             subgroupId: 0,
                                             objectId: 0,
                                             fixtureIndex: 0,
                                             activity: snapshot.activity,
                                             actionID: snapshot.actionID,
                                             rollReason: self.startingRollReason,
                                             closeGroupId: nil,
                                             closeSubgroupId: nil,
                                             transition: nextTransition,
                                             handledNGRGeneration: snapshot.requestedNGRGeneration)
                    firstCandidate = false
                    continue
                }
                let naturalRoll = fixtureIndex >= self.fixture.accessUnits.count
                let ngr = snapshot.requestedNGRGeneration > handledNGRGeneration
                let reason: TopNGroupRollReason?
                if ngr {
                    reason = .newGroupRequest
                } else if activityResult.rollGroup {
                    reason = .activityRise
                } else if naturalRoll {
                    reason = .naturalGOP
                } else {
                    reason = nil
                }
                let rollsGroup = reason != nil
                let rollsSubgroup = !rollsGroup && activityResult.rollSubgroup
                if rollsGroup {
                    pendingCandidate = .init(groupId: groupId + 1,
                                             subgroupId: 0,
                                             objectId: 0,
                                             fixtureIndex: 0,
                                             activity: snapshot.activity,
                                             actionID: snapshot.actionID,
                                             rollReason: reason,
                                             closeGroupId: subgroupOpen ? groupId : nil,
                                             closeSubgroupId: subgroupOpen ? subgroupId : nil,
                                             transition: nextTransition,
                                             handledNGRGeneration: snapshot.requestedNGRGeneration)
                } else {
                    pendingCandidate = .init(groupId: groupId,
                                             subgroupId: rollsSubgroup ? subgroupId + 1 : subgroupId,
                                             objectId: objectId,
                                             fixtureIndex: fixtureIndex,
                                             activity: snapshot.activity,
                                             actionID: snapshot.actionID,
                                             rollReason: nil,
                                             closeGroupId: rollsSubgroup && subgroupOpen ? groupId : nil,
                                             closeSubgroupId: rollsSubgroup && subgroupOpen ? subgroupId : nil,
                                             transition: nextTransition,
                                             handledNGRGeneration: handledNGRGeneration)
                }
            }

            if let candidate = pendingCandidate, self.sink.canPublish {
                if let closeGroupId = candidate.closeGroupId,
                   let closeSubgroupId = candidate.closeSubgroupId {
                    self.sink.endSubgroup(groupId: closeGroupId, subgroupId: closeSubgroupId, completed: true)
                    subgroupOpen = false
                }
                let frame = self.fixture.accessUnits[candidate.fixtureIndex]
                do {
                    var extensions = HeaderExtensions()
                    try extensions.setHeader(.captureTimestamp(.now))
                    try extensions.setHeader(.audioActivityIndicator(candidate.activity.rawValue))
                    try extensions.setHeader(.publishTimestamp(.now))
                    var priority = try self.profile.getPriority(index: frame.isIDR ? 0 : 1)
                    var ttl = try self.profile.getTTL(index: frame.isIDR ? 0 : 1)
                    let status = withUnsafePointer(to: &priority) { priorityPointer in
                        withUnsafePointer(to: &ttl) { ttlPointer in
                            let headers = QObjectHeaders(groupId: candidate.groupId,
                                                         subgroupId: candidate.subgroupId,
                                                         objectId: candidate.objectId,
                                                         payloadLength: UInt64(frame.payload.count),
                                                         status: .available,
                                                         priority: priorityPointer,
                                                         ttl: ttlPointer)
                            return self.sink.publishObject(headers,
                                                           data: frame.payload,
                                                           extensions: extensions,
                                                           immutableExtensions: nil,
                                                           streamHeaderProperties: nil)
                        }
                    }
                    self.onPublished(.init(fullTrackName: self.sink.fullTrackName,
                                           groupId: candidate.groupId,
                                           subgroupId: candidate.subgroupId,
                                           objectId: candidate.objectId,
                                           fixtureIndex: candidate.fixtureIndex,
                                           activity: candidate.activity,
                                           activityActionID: candidate.actionID,
                                           rollReason: candidate.rollReason,
                                           status: status,
                                           at: .now))
                    guard status == .ok else {
                        deadline += interval
                        try? await clock.sleep(until: deadline)
                        continue
                    }
                    groupId = candidate.groupId
                    subgroupId = candidate.subgroupId
                    objectId = candidate.objectId + 1
                    fixtureIndex = candidate.fixtureIndex + 1
                    transition = candidate.transition
                    handledNGRGeneration = candidate.handledNGRGeneration
                    subgroupOpen = true
                    self.control.withLock { $0.lastSuccessfulGroupId = groupId }
                    self.control.withLock { $0.actionID = nil }
                    pendingCandidate = nil
                } catch {
                    // Keep the candidate intact so a transient profile or sink failure is retried.
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

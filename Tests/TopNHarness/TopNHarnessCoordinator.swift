// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
@testable import QuicR

@MainActor
final class TopNHarnessCoordinator {
    private let configuration: TopNHarnessConfiguration
    private var participants: [TopNParticipantID: TopNHarnessParticipant] = [:]
    private var presence: [TopNParticipantID: Presence] = [:]
    private var faultController: TopNHarnessFaultController?
    private var reservedGroupIds = Set<UInt64>()
    private var activity: [TopNParticipantID: TopNActivity] = [:]
    private var checkpointsExecuted = 0
    private var checkpointsPassed = 0
    private var presentationHost: TopNHarnessPresentationHost?

    private enum Presence { case offline, joining, online }

    init(configuration: TopNHarnessConfiguration) {
        self.configuration = configuration
    }

    func run() async throws {
        let startedAt = Date.now
        let artifactDirectory = URL(fileURLWithPath: self.configuration.artifactDirectory)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let fixture = try TopNH264Fixture.loadFromTestBundle()
        try await TopNHarnessPreflight.validateFixture(fixture)
        let scenario = try TopNScenarioResolver().resolve(selection: self.configuration.scenario,
                                                          participants: self.configuration.participants)
        _ = try scenario.validated(configuration: self.configuration)
        self.presentationHost = try TopNHarnessPresentationHost()
        try Self.writeScenario(scenario, to: artifactDirectory.appendingPathComponent("scenario.json"))
        let recorder = TopNHarnessRecorder()
        self.checkpointsExecuted = 0
        self.checkpointsPassed = 0
        let faultController = TopNHarnessFaultController(rules: self.configuration.faults, recorder: recorder)
        self.faultController = faultController
        for participant in self.configuration.participants {
            self.presence[participant] = .offline
            self.activity[participant] = .speechEnd
            let participantIndex = UInt16(self.configuration.participants.firstIndex(of: participant)! + 1)
            self.participants[participant] = TopNHarnessParticipant(
                id: participant,
                participantIndex: participantIndex,
                configuration: self.configuration,
                fixture: fixture,
                recorder: recorder,
                faultController: faultController,
                isParticipantEligible: { [weak self] remote in
                    guard let self else { return false }
                    return self.presence[remote] != .offline
                },
                onVideoParticipantsReady: { [weak self] videoParticipants in
                    self?.presentationHost?.attachGrid(videoParticipants,
                                                       topN: self?.configuration.topN ?? 1,
                                                       slot: participant.rawValue)
                })
        }

        do {
            for participantID in self.configuration.participants {
                guard let participant = self.participants[participantID] else { continue }
                self.presence[participantID] = .joining
                try await participant.join(startingGroupId: try self.reserveNextGroupId(), startingRollReason: .initial)
                self.presence[participantID] = .online
            }
            let checkpointCounts: (executed: Int, passed: Int)
            if self.configuration.scenario.kind == .roundRobin,
               let duration = self.configuration.scenario.durationMilliseconds {
                checkpointCounts = try await self.executeRoundRobin(durationMilliseconds: duration,
                                                                    recorder: recorder)
            } else {
                checkpointCounts = try await self.execute(scenario, recorder: recorder)
            }
            let endedAt = Date.now
            let summary = TopNHarnessSummary(version: 1, outcomeClass: .passed, startedAt: startedAt,
                                             endedAt: endedAt, scenarioName: scenario.name, seed: scenario.seed,
                                             joinPolicy: self.configuration.joinPolicy,
                                             checkpointsExecuted: checkpointCounts.executed,
                                             checkpointsPassed: checkpointCounts.passed,
                                             failure: nil)
            try recorder.flushEvents(to: artifactDirectory.appendingPathComponent("events.jsonl"))
            try recorder.writeSummary(summary, to: artifactDirectory.appendingPathComponent("summary.json"))
        } catch {
            try? await Task.sleep(for: .milliseconds(Int64(self.configuration.deadlines.diagnosticDrainSeconds * 1000)))
            await self.leaveAll(reason: "coordinator-failure")
            let failure = Self.failureDetail(for: error)
            let summary = TopNHarnessSummary(version: 1, outcomeClass: failure.outcomeClass,
                                             startedAt: startedAt, endedAt: Date.now,
                                             scenarioName: scenario.name, seed: scenario.seed,
                                             joinPolicy: self.configuration.joinPolicy,
                                             checkpointsExecuted: self.checkpointsExecuted,
                                             checkpointsPassed: self.checkpointsPassed,
                                             failure: failure)
            do {
                try recorder.flushEvents(to: artifactDirectory.appendingPathComponent("events.jsonl"))
                try recorder.writeSummary(summary, to: artifactDirectory.appendingPathComponent("summary.json"))
            } catch {
                throw TopNHarnessFailure.infrastructure("\(failure.message); artefact write failed: \(error)")
            }
            throw TopNHarnessFailure(detail: failure)
        }
        await self.leaveAll(reason: "completed")
    }

    private func execute(_ scenario: TopNScenario, recorder: TopNHarnessRecorder) async throws -> (executed: Int, passed: Int) {
        let clock = ContinuousClock()
        let origin = clock.now
        var checkpointCount = 0
        var checkpointWindowStartMilliseconds = 0.0
        var inactiveSince = Dictionary(uniqueKeysWithValues: self.configuration.participants.map { ($0, 0.0) })
        var activeSince: [TopNParticipantID: Double] = [:]
        var firstLifecycleFailure: TopNHarnessFailureDetail?
        for action in scenario.actions {
            let deadline = origin + .milliseconds(Int64(action.atMilliseconds))
            try await clock.sleep(until: deadline)
            let eventClient = action.participant ?? self.configuration.participants[0]
            recorder.recordHarnessEvent(client: eventClient, connectionGeneration: self.participants[eventClient]?.generationNumber ?? 0,
                                        scheduledMilliseconds: Double(action.atMilliseconds), actionID: action.id,
                                        stage: .scenarioAction, details: .init(reason: action.kind.rawValue))
            let actionStartMilliseconds = recorder.snapshot().last?.elapsedMilliseconds ?? 0
            switch action.kind {
            case .activity:
                guard let participant = action.participant, let activity = action.activity,
                      let instance = self.participants[participant] else { continue }
                try instance.setActivity(activity, actionID: action.id)
                self.activity[participant] = activity
                checkpointWindowStartMilliseconds = actionStartMilliseconds
                if activity == .speechEnd {
                    inactiveSince[participant] = actionStartMilliseconds
                } else if activity == .speechStart {
                    activeSince[participant] = actionStartMilliseconds
                }
            case .leave:
                guard let participant = action.participant, let instance = self.participants[participant] else { continue }
                self.presence[participant] = .offline
                self.activity[participant] = .speechEnd
                await instance.leave(reason: action.id)
                checkpointWindowStartMilliseconds = actionStartMilliseconds
            case .rejoin:
                guard let participant = action.participant, let instance = self.participants[participant] else { continue }
                self.presence[participant] = .joining
                let normalGroupId = try self.reserveNextGroupId()
                let previousGroupId = instance.retainedLastSuccessfulGroupId ?? 0
                let decision = try self.faultController?.reconnectGroupDecision(
                    publisher: participant, connectionGeneration: instance.generationNumber + 1,
                    previousSuccessfulGroupId: previousGroupId, normalGroupId: normalGroupId)
                    ?? .normal(normalGroupId)
                let chosen: UInt64
                let reason: TopNGroupRollReason
                switch decision {
                case .normal(let groupId): chosen = groupId; reason = .reconnect
                case .injected(let groupId, let rollReason): chosen = groupId; reason = rollReason
                }
                try await instance.join(startingGroupId: chosen, startingRollReason: reason)
                recorder.recordHarnessEvent(client: participant,
                                            connectionGeneration: instance.generationNumber,
                                            groupId: chosen, actionID: action.id, stage: .connectionRejoined,
                                            details: .init(reason: reason.rawValue,
                                                           previousGroupId: previousGroupId))
                self.presence[participant] = .online
                checkpointWindowStartMilliseconds = actionStartMilliseconds
            case .checkpoint:
                checkpointCount += 1
                self.checkpointsExecuted = checkpointCount
                try await Task.sleep(for: .milliseconds(10))
                if let name = action.name,
                   let publisher = Self.lifecyclePublisher(from: name) {
                    let failures: [TopNHarnessFailureDetail]
                    do {
                        try await self.assertCheckpoint(name: name,
                                                        stageWindowStartMilliseconds: checkpointWindowStartMilliseconds,
                                                        recorder: recorder)
                        failures = await self.waitForLifecycleFailures(
                            publisher: publisher,
                            inactiveSinceMilliseconds: inactiveSince[publisher] ?? 0,
                            activeSinceMilliseconds: activeSince[publisher] ?? 0,
                            recorder: recorder)
                    } catch let failure as TopNHarnessFailure {
                        failures = [failure.detail]
                    }
                    if failures.isEmpty {
                        self.checkpointsPassed += 1
                    } else if firstLifecycleFailure == nil {
                        firstLifecycleFailure = failures[0]
                    }
                } else {
                    try await self.assertCheckpoint(name: action.name ?? action.id,
                                                    stageWindowStartMilliseconds: checkpointWindowStartMilliseconds,
                                                    recorder: recorder)
                    self.checkpointsPassed += 1
                }
                recorder.recordHarnessEvent(client: self.configuration.participants[0],
                                            connectionGeneration: 0,
                                            scheduledMilliseconds: Double(action.atMilliseconds),
                                            actionID: action.id, stage: .checkpoint,
                                            details: .init(reason: action.name))
            case .enableFault:
                guard let faultID = action.faultID else { throw TopNHarnessFailure.infrastructure("missing fault ID") }
                try self.faultController?.enable(id: faultID)
                recorder.recordHarnessEvent(client: self.configuration.participants[0],
                                            connectionGeneration: 0,
                                            scheduledMilliseconds: Double(action.atMilliseconds),
                                            actionID: action.id, stage: .faultEnabled,
                                            details: .init(faultID: faultID))
            case .disableFault:
                guard let faultID = action.faultID else { throw TopNHarnessFailure.infrastructure("missing fault ID") }
                try self.faultController?.disable(id: faultID)
                recorder.recordHarnessEvent(client: self.configuration.participants[0],
                                            connectionGeneration: 0,
                                            scheduledMilliseconds: Double(action.atMilliseconds),
                                            actionID: action.id, stage: .faultDisabled,
                                            details: .init(faultID: faultID))
            }
        }
        if let firstLifecycleFailure {
            throw TopNHarnessFailure(detail: firstLifecycleFailure)
        }
        return (checkpointCount, checkpointCount)
    }

    private static func lifecyclePublisher(from checkpoint: String) -> TopNParticipantID? {
        let components = checkpoint.split(separator: ":")
        guard components.count == 3, components[0] == "lifecycle-reactivation" else { return nil }
        return .init(rawValue: String(components[1]))
    }

    private func recordPresentation(subscriber: TopNParticipantID,
                                    publisher: TopNParticipantID,
                                    activeSinceMilliseconds: Double,
                                    recorder: TopNHarnessRecorder) async -> TopNHarnessFailureDetail? {
        let events = recorder.snapshot()
        let generation = events.last {
            $0.client == subscriber && $0.remoteParticipant == publisher &&
                $0.elapsedMilliseconds >= activeSinceMilliseconds &&
                $0.stage == .handlerCreated
        }?.handlerGeneration ?? events.last {
            $0.client == subscriber && $0.remoteParticipant == publisher &&
                $0.elapsedMilliseconds >= activeSinceMilliseconds
        }?.handlerGeneration
        let participant = self.participants[subscriber]
        guard let presentationHost = self.presentationHost,
              let participant,
              let videoView = participant.videoView(for: publisher) else {
            let reason = "presentation view unavailable"
            recorder.recordHarnessEvent(client: subscriber,
                                        connectionGeneration: participant?.generationNumber ?? 0,
                                        remoteParticipant: publisher,
                                        handlerGeneration: generation,
                                        stage: .displayError,
                                        details: .init(reason: reason))
            return self.presentationFailure(reason: reason, subscriber: subscriber,
                                            publisher: publisher, generation: generation)
        }
        do {
            let timeout = Duration.milliseconds(
                Int64(self.configuration.deadlines.mediaConvergenceSeconds * 1_000))
            let sample = try await presentationHost.capture(videoView, timeout: timeout)
            recorder.recordHarnessEvent(client: subscriber,
                                        connectionGeneration: participant.generationNumber,
                                        remoteParticipant: publisher,
                                        handlerGeneration: generation,
                                        stage: .displayPresented,
                                        details: .init(reason: "meanLuma=\(sample.meanLuma) " +
                                                        "source=\(sample.source) motionObserved=\(sample.motionObserved)"))
            return nil
        } catch {
            let reason = "presentation probe: \(error); \(presentationHost.diagnostics(videoView))"
            recorder.recordHarnessEvent(client: subscriber,
                                        connectionGeneration: participant.generationNumber,
                                        remoteParticipant: publisher,
                                        handlerGeneration: generation,
                                        stage: .displayError,
                                        details: .init(reason: reason))
            return self.presentationFailure(reason: reason, subscriber: subscriber,
                                            publisher: publisher, generation: generation)
        }
    }

    private func presentationFailure(reason: String,
                                     subscriber: TopNParticipantID,
                                     publisher: TopNParticipantID,
                                     generation: UInt64?) -> TopNHarnessFailureDetail {
        .init(outcomeClass: .clientMedia,
              message: reason,
              subscriber: subscriber, publisher: publisher,
              connectionGeneration: self.participants[subscriber]?.generationNumber,
              handlerGeneration: generation, renderEpoch: nil,
              groupId: nil, objectId: nil, lastSuccessfulStage: .displayEnqueued)
    }

    private func lifecycleFailures(publisher: TopNParticipantID,
                                   inactiveSinceMilliseconds: Double,
                                   activeSinceMilliseconds: Double,
                                   recorder: TopNHarnessRecorder) -> [TopNHarnessFailureDetail] {
        let events = recorder.snapshot()
        let now = events.last?.elapsedMilliseconds ?? activeSinceMilliseconds
        return self.configuration.participants.compactMap { subscriber in
            guard subscriber != publisher,
                  let code = TopNHarnessOracle.lifecycleReactivationFailure(
                    in: events, subscriber: subscriber, publisher: publisher,
                    inactiveSinceMilliseconds: inactiveSinceMilliseconds,
                    activeSinceMilliseconds: activeSinceMilliseconds,
                    nowMilliseconds: now,
                    maxDisplayGapMilliseconds: self.configuration.deadlines.maxDisplayGapSeconds * 1_000
                  ) else { return nil }
            let last = events.last {
                $0.client == subscriber && $0.remoteParticipant == publisher
            }
            return .init(outcomeClass: .clientMedia,
                         message: "lifecycle reactivation \(code.rawValue) for " +
                            "\(subscriber.rawValue) <- \(publisher.rawValue)",
                         subscriber: subscriber, publisher: publisher,
                         connectionGeneration: self.participants[subscriber]?.generationNumber,
                         handlerGeneration: last?.handlerGeneration, renderEpoch: last?.renderEpoch,
                         groupId: last?.groupId, objectId: last?.objectId,
                         lastSuccessfulStage: last?.stage)
        }
    }

    private func waitForLifecycleFailures(publisher: TopNParticipantID,
                                          inactiveSinceMilliseconds: Double,
                                          activeSinceMilliseconds: Double,
                                          recorder: TopNHarnessRecorder) async -> [TopNHarnessFailureDetail] {
        let deadline = ContinuousClock.now + .seconds(self.configuration.deadlines.mediaConvergenceSeconds)
        while true {
            let failures = self.lifecycleFailures(publisher: publisher,
                                                  inactiveSinceMilliseconds: inactiveSinceMilliseconds,
                                                  activeSinceMilliseconds: activeSinceMilliseconds,
                                                  recorder: recorder)
            guard !failures.isEmpty, ContinuousClock.now < deadline else { return failures }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func executeRoundRobin(durationMilliseconds: UInt64,
                                   recorder: TopNHarnessRecorder) async throws -> (executed: Int, passed: Int) {
        let clock = ContinuousClock()
        let end = clock.now + .milliseconds(Int64(durationMilliseconds))
        var previous: TopNParticipantID?
        var turn = 0
        while clock.now < end {
            let current = self.configuration.participants[turn % self.configuration.participants.count]
            let actionID = "round-robin-\(turn)-\(current.rawValue)"
            let windowStart = try self.recordActivity(.speechStart, participant: current,
                                                      actionID: "\(actionID)-start", recorder: recorder)
            try await Task.sleep(for: .milliseconds(150))
            if let previous {
                _ = try self.recordActivity(.speechEnd, participant: previous,
                                            actionID: "\(actionID)-previous-end", recorder: recorder)
            }
            _ = try self.recordActivity(.continuousSpeech, participant: current,
                                        actionID: "\(actionID)-continuous", recorder: recorder)
            self.checkpointsExecuted = turn + 1
            try await self.assertCheckpoint(name: actionID,
                                            stageWindowStartMilliseconds: windowStart,
                                            recorder: recorder)
            self.checkpointsPassed = turn + 1
            recorder.recordHarnessEvent(client: current,
                                        connectionGeneration: self.participants[current]?.generationNumber ?? 0,
                                        actionID: "\(actionID)-checkpoint", stage: .checkpoint,
                                        details: .init(reason: actionID))
            previous = current
            turn += 1
        }
        if let previous {
            _ = try self.recordActivity(.speechEnd, participant: previous,
                                        actionID: "round-robin-complete", recorder: recorder)
        }
        return (turn, turn)
    }

    private func recordActivity(_ activity: TopNActivity,
                                participant: TopNParticipantID,
                                actionID: String,
                                recorder: TopNHarnessRecorder) throws -> Double {
        recorder.recordHarnessEvent(client: participant,
                                    connectionGeneration: self.participants[participant]?.generationNumber ?? 0,
                                    actionID: actionID, stage: .scenarioAction,
                                    details: .init(reason: TopNScenarioAction.Kind.activity.rawValue))
        let started = recorder.snapshot().last?.elapsedMilliseconds ?? 0
        guard let instance = self.participants[participant] else {
            throw TopNHarnessFailure.infrastructure("missing round-robin participant \(participant.rawValue)")
        }
        try instance.setActivity(activity, actionID: actionID)
        self.activity[participant] = activity
        return started
    }

    private func leaveAll(reason: String) async {
        for participantID in self.configuration.participants.reversed() {
            self.presence[participantID] = .offline
            await self.participants[participantID]?.leave(reason: reason)
        }
    }

    private static func writeScenario(_ scenario: TopNScenario, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(scenario)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private func reserveNextGroupId() throws -> UInt64 {
        var maximum = self.reservedGroupIds.max() ?? 0
        for participant in self.participants.values {
            maximum = max(maximum, participant.generation?.publication.lastSuccessfulGroupId ?? 0)
            maximum = max(maximum, participant.retainedLastSuccessfulGroupId ?? 0)
        }
        guard maximum < UInt64.max else {
            throw TopNHarnessFailure.infrastructure("group ID allocator overflow")
        }
        let next = maximum + 1
        self.reservedGroupIds.insert(next)
        return next
    }

    private func assertCheckpoint(name: String,
                                  stageWindowStartMilliseconds: Double,
                                  recorder: TopNHarnessRecorder) async throws {
        let deadline = ContinuousClock.now + .seconds(self.configuration.deadlines.mediaConvergenceSeconds)
        while true {
            if let failure = self.checkpointFailure(name: name,
                                                    stageWindowStartMilliseconds: stageWindowStartMilliseconds,
                                                    recorder: recorder) {
                guard ContinuousClock.now < deadline else { throw TopNHarnessFailure(detail: failure) }
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            break
        }

        let online = Set(self.presence.compactMap { $0.value == .online ? $0.key : nil })
        let events = recorder.snapshot()
        let deliveryWindowStart = self.deliveryWindowStart(stageWindowStartMilliseconds, events: events)
        for subscriber in online {
            let view = TopNHarnessOracle.resolve(subscriber: subscriber, activity: self.activity,
                                                 online: online, topN: self.configuration.topN)
            let delivered = Set(events.lazy.filter {
                $0.client == subscriber && $0.elapsedMilliseconds >= deliveryWindowStart &&
                    $0.stage == .objectReceived
            }.compactMap(\.remoteParticipant))
            let expected = view.required.isEmpty ? delivered.intersection(view.allowed) : view.required
            for publisher in expected {
                if let failure = await self.recordPresentation(
                    subscriber: subscriber, publisher: publisher,
                    activeSinceMilliseconds: stageWindowStartMilliseconds,
                    recorder: recorder) {
                    throw TopNHarnessFailure(detail: failure)
                }
            }
        }
    }

    private func checkpointFailure(name: String,
                                   stageWindowStartMilliseconds: Double,
                                   recorder: TopNHarnessRecorder) -> TopNHarnessFailureDetail? {
        let online = Set(self.presence.compactMap { $0.value == .online ? $0.key : nil })
        let events = recorder.snapshot()
        let deliveryWindowStart = self.deliveryWindowStart(stageWindowStartMilliseconds, events: events)
        for subscriber in online {
            let view = TopNHarnessOracle.resolve(subscriber: subscriber, activity: self.activity,
                                                 online: online, topN: self.configuration.topN)
            let delivered = Set(events.lazy.filter {
                $0.client == subscriber && $0.elapsedMilliseconds >= deliveryWindowStart &&
                    $0.stage == .objectReceived
            }.compactMap(\.remoteParticipant))
            if let violation = TopNHarnessOracle.deliveryViolations(
                subscriber: subscriber, view: view, online: online, delivered: delivered).first {
                let rejectedCandidates = violation.publisher.map { Set([$0]) } ??
                    (view.required.isEmpty ? view.allowed : view.required)
                let locallyRejected = events.contains { event in
                    event.client == subscriber && event.stage == .publishRejected &&
                        event.connectionGeneration == self.participants[subscriber]?.generationNumber &&
                        event.remoteParticipant.map(rejectedCandidates.contains) == true
                }
                return .init(outcomeClass: locallyRejected ? .infrastructure : .relayConvergence,
                             message: "checkpoint \(name) \(violation.code.rawValue) for \(subscriber.rawValue)",
                             subscriber: subscriber, publisher: violation.publisher,
                             connectionGeneration: self.participants[subscriber]?.generationNumber,
                             handlerGeneration: nil, renderEpoch: nil, groupId: nil, objectId: nil,
                             lastSuccessfulStage: nil)
            }
            let expected = view.required.isEmpty ? delivered.intersection(view.allowed) : view.required
            for publisher in expected {
                let path = events.filter { event in
                    event.client == subscriber && event.remoteParticipant == publisher
                }
                guard let missingStage = TopNHarnessOracle.missingRequiredStage(
                    in: path,
                    since: stageWindowStartMilliseconds
                ) else { continue }
                let currentPath = path.filter { $0.elapsedMilliseconds >= stageWindowStartMilliseconds }
                let lastStage = currentPath.last?.stage
                return .init(
                    outcomeClass: missingStage == .objectReceived ? .relayConvergence : .clientMedia,
                    message: "checkpoint \(name) missing \(missingStage.rawValue) for \(subscriber.rawValue) <- \(publisher.rawValue)",
                    subscriber: subscriber, publisher: publisher,
                    connectionGeneration: self.participants[subscriber]?.generationNumber,
                    handlerGeneration: currentPath.last?.handlerGeneration,
                    renderEpoch: currentPath.last?.renderEpoch,
                    groupId: currentPath.last?.groupId, objectId: currentPath.last?.objectId,
                    lastSuccessfulStage: lastStage)
            }
        }
        return nil
    }

    private func deliveryWindowStart(_ stageWindowStartMilliseconds: Double,
                                     events: [TopNHarnessRecordedEvent]) -> Double {
        max(stageWindowStartMilliseconds,
            (events.last?.elapsedMilliseconds ?? 0) -
                self.configuration.deadlines.maxDisplayGapSeconds * 1_000)
    }

    private static func failureDetail(for error: Error) -> TopNHarnessFailureDetail {
        if let failure = error as? TopNHarnessFailure {
            return .init(outcomeClass: failure.detail.outcomeClass,
                         message: failure.detail.message,
                         subscriber: failure.detail.subscriber, publisher: failure.detail.publisher,
                         connectionGeneration: failure.detail.connectionGeneration,
                         handlerGeneration: failure.detail.handlerGeneration,
                         renderEpoch: failure.detail.renderEpoch, groupId: failure.detail.groupId,
                         objectId: failure.detail.objectId,
                         lastSuccessfulStage: failure.detail.lastSuccessfulStage)
        }
        return .init(outcomeClass: .infrastructure,
                     message: error.localizedDescription,
                     subscriber: nil, publisher: nil, connectionGeneration: nil,
                     handlerGeneration: nil, renderEpoch: nil, groupId: nil, objectId: nil,
                     lastSuccessfulStage: nil)
    }
}

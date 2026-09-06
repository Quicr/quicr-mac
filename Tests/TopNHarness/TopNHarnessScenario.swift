// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

extension TopNScenario {
    func validated(configuration: TopNHarnessConfiguration) throws -> Self {
        guard self.version == 1,
              !self.actions.isEmpty || configuration.scenario.kind == .roundRobin else {
            throw TopNHarnessFailure.infrastructure("scenario must have version 1 and actions unless it is roundRobin")
        }
        var ids = Set<String>()
        var previousTime: UInt64 = 0
        var checkpoints = Set<UInt64>()
        var online = Set(configuration.participants)
        let configuredFaults = Set(configuration.faults.map(\.id))
        var enabledFaults = Set<String>()
        for (index, action) in self.actions.enumerated() {
            guard !action.id.isEmpty, ids.insert(action.id).inserted else {
                throw TopNHarnessFailure.infrastructure("scenario action IDs must be unique and non-empty")
            }
            guard index == 0 || action.atMilliseconds >= previousTime else {
                throw TopNHarnessFailure.infrastructure("scenario actions must be ordered")
            }
            previousTime = action.atMilliseconds
            if let participant = action.participant, !configuration.participants.contains(participant) {
                throw TopNHarnessFailure.infrastructure("scenario references unknown participant \(participant.rawValue)")
            }
            switch action.kind {
            case .activity:
                guard let participant = action.participant, action.activity != nil,
                      action.name == nil, action.faultID == nil, online.contains(participant) else {
                    throw TopNHarnessFailure.infrastructure("invalid activity action \(action.id)")
                }
            case .leave:
                guard let participant = action.participant, action.activity == nil,
                      action.name == nil, action.faultID == nil, online.contains(participant) else {
                    throw TopNHarnessFailure.infrastructure("invalid leave action \(action.id)")
                }
                online.remove(participant)
            case .rejoin:
                guard let participant = action.participant, action.activity == nil,
                      action.name == nil, action.faultID == nil, !online.contains(participant) else {
                    throw TopNHarnessFailure.infrastructure("invalid rejoin action \(action.id)")
                }
                online.insert(participant)
            case .checkpoint:
                guard let name = action.name, !name.isEmpty, action.participant == nil,
                      action.activity == nil, action.faultID == nil, checkpoints.insert(action.atMilliseconds).inserted else {
                    throw TopNHarnessFailure.infrastructure("invalid checkpoint action \(action.id)")
                }
            case .enableFault, .disableFault:
                guard let faultID = action.faultID, configuredFaults.contains(faultID),
                      action.participant == nil,
                      action.activity == nil, action.name == nil else {
                    throw TopNHarnessFailure.infrastructure("invalid fault action \(action.id)")
                }
                if action.kind == .enableFault {
                    guard enabledFaults.insert(faultID).inserted else {
                        throw TopNHarnessFailure.infrastructure("fault is already enabled: \(faultID)")
                    }
                } else {
                    guard enabledFaults.remove(faultID) != nil else {
                        throw TopNHarnessFailure.infrastructure("fault is not enabled: \(faultID)")
                    }
                }
            }
        }
        if [.seeded, .lifecycleConversation].contains(configuration.scenario.kind),
           let duration = configuration.scenario.durationMilliseconds,
           previousTime > duration {
            throw TopNHarnessFailure.infrastructure("scenario exceeds its configured duration")
        }
        return self
    }
}

struct TopNScenarioResolver: Sendable {
    func resolve(selection: TopNScenarioSelection,
                 participants: [TopNParticipantID]) throws -> TopNScenario {
        switch selection.kind {
        case .replay:
            guard let path = selection.replayPath else { throw TopNHarnessFailure.infrastructure("missing replay path") }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(TopNScenario.self, from: data)
        case .builtIn:
            guard let builtIn = selection.builtIn else { throw TopNHarnessFailure.infrastructure("missing built-in scenario") }
            return .init(version: 1, name: builtIn.rawValue, seed: nil, participants: participants,
                         actions: Self.builtIn(builtIn, participants: participants))
        case .seeded:
            guard let seed = selection.seed, let duration = selection.durationMilliseconds else {
                throw TopNHarnessFailure.infrastructure("seeded scenario is missing seed or duration")
            }
            return .init(version: 1, name: "seeded", seed: seed, participants: participants,
                         actions: self.seeded(seed: seed, durationMilliseconds: duration, participants: participants))
        case .lifecycleConversation:
            guard let seed = selection.seed, let duration = selection.durationMilliseconds else {
                throw TopNHarnessFailure.infrastructure("lifecycleConversation is missing seed or duration")
            }
            return .init(version: 1, name: "lifecycle-conversation", seed: seed, participants: participants,
                         actions: self.lifecycleConversation(seed: seed,
                                                             durationMilliseconds: duration,
                                                             participants: participants))
        case .roundRobin:
            guard let duration = selection.durationMilliseconds, duration > 0 else {
                throw TopNHarnessFailure.infrastructure("roundRobin scenario is missing its duration")
            }
            return .init(version: 1, name: "round-robin", seed: nil, participants: participants, actions: [])
        }
    }

    private static func builtIn(_ scenario: TopNBuiltInScenario,
                                participants: [TopNParticipantID]) -> [TopNScenarioAction] {
        func activity(_ id: String, _ at: UInt64, _ participant: TopNParticipantID, _ value: TopNActivity) -> TopNScenarioAction {
            .init(id: id, atMilliseconds: at, kind: .activity, participant: participant, activity: value, name: nil, faultID: nil)
        }
        func checkpoint(_ id: String, _ at: UInt64) -> TopNScenarioAction {
            .init(id: id, atMilliseconds: at, kind: .checkpoint, participant: nil, activity: nil, name: id, faultID: nil)
        }
        func lifecycle(_ id: String, _ at: UInt64, _ kind: TopNScenarioAction.Kind,
                       _ participant: TopNParticipantID) -> TopNScenarioAction {
            .init(id: id, atMilliseconds: at, kind: kind, participant: participant,
                  activity: nil, name: nil, faultID: nil)
        }
        var actions = participants.map { activity("\(scenario.rawValue)-0-\($0.rawValue)-end", 0, $0, .speechEnd) }
        switch scenario {
        case .orderly:
            guard let p1 = participants.first, participants.count >= 3 else { return actions }
            let p2 = participants[1], p3 = participants[2]
            actions += [activity("orderly-500-p1-start", 500, p1, .speechStart),
                        activity("orderly-1000-p1-continuous", 1000, p1, .continuousSpeech), checkpoint("orderly-p1", 1500),
                        activity("orderly-3000-p1-end", 3000, p1, .speechEnd), activity("orderly-3000-p2-start", 3000, p2, .speechStart),
                        activity("orderly-3500-p2-continuous", 3500, p2, .continuousSpeech), checkpoint("orderly-p2", 4000),
                        activity("orderly-5500-p2-end", 5500, p2, .speechEnd), activity("orderly-5500-p3-start", 5500, p3, .speechStart),
                        activity("orderly-6000-p3-continuous", 6000, p3, .continuousSpeech), checkpoint("orderly-p3", 6500),
                        activity("orderly-8000-p3-end", 8000, p3, .speechEnd), checkpoint("orderly-silence", 8500)]
        case .overlap:
            guard participants.count >= 3 else { return actions }
            let p1 = participants[0], p2 = participants[1], p3 = participants[2]
            actions += [activity("overlap-500-p1-start", 500, p1, .speechStart), checkpoint("overlap-p1", 1000),
                        activity("overlap-1500-p2-start", 1500, p2, .speechStart), activity("overlap-2000-p2-continuous", 2000, p2, .continuousSpeech),
                        activity("overlap-4000-p1-end", 4000, p1, .speechEnd), checkpoint("overlap-p2-selected-mid-gop", 4500),
                        activity("overlap-6000-p1-continuous", 6000, p1, .continuousSpeech), checkpoint("overlap-continuous-tie", 6500),
                        activity("overlap-8000-p1-end", 8000, p1, .speechEnd), checkpoint("overlap-p2-remains", 8500),
                        activity("overlap-9500-p3-start", 9500, p3, .speechStart), activity("overlap-9750-p3-end", 9750, p3, .speechEnd),
                        checkpoint("overlap-after-short-interruption", 10500), activity("overlap-11500-p2-end", 11500, p2, .speechEnd),
                        checkpoint("overlap-silence", 12000)]
        case .lifecycle:
            guard participants.count >= 3 else { return actions }
            let p1 = participants[0], p2 = participants[1], p3 = participants[2]
            actions += [activity("lifecycle-500-p1-start", 500, p1, .speechStart),
                        activity("lifecycle-1000-p1-continuous", 1000, p1, .continuousSpeech),
                        checkpoint("lifecycle-p1-before-p3-leave", 1500),
                        lifecycle("lifecycle-2000-p3-leave", 2000, .leave, p3),
                        checkpoint("lifecycle-p3-offline", 2500),
                        lifecycle("lifecycle-3000-p3-rejoin", 3000, .rejoin, p3),
                        checkpoint("lifecycle-p3-rejoined-sees-p1", 4000),
                        lifecycle("lifecycle-5000-p1-leave", 5000, .leave, p1),
                        activity("lifecycle-5250-p2-start", 5250, p2, .speechStart), activity("lifecycle-5750-p2-continuous", 5750, p2, .continuousSpeech),
                        checkpoint("lifecycle-p2-replaces-p1", 6500), lifecycle("lifecycle-7000-p1-rejoin", 7000, .rejoin, p1),
                        checkpoint("lifecycle-p1-rejoined-sees-p2", 8000), activity("lifecycle-8500-p1-start", 8500, p1, .speechStart),
                        activity("lifecycle-9000-p1-continuous", 9000, p1, .continuousSpeech), activity("lifecycle-9000-p2-end", 9000, p2, .speechEnd),
                        checkpoint("lifecycle-p1-rejoined-is-eligible", 10000), activity("lifecycle-10500-p1-end", 10500, p1, .speechEnd),
                        checkpoint("lifecycle-silence", 11000)]
        case .dropIDRRecovery:
            guard participants.count >= 3 else { return actions }
            let p1 = participants[0], p2 = participants[1], p3 = participants[2]
            return actions + [activity("drop-idr-500-p2-start", 500, p2, .speechStart),
                              activity("drop-idr-1000-p2-continuous", 1000, p2, .continuousSpeech),
                              checkpoint("drop-idr-p2-precondition", 1500),
                              .init(id: "drop-idr-enable", atMilliseconds: 3500, kind: .enableFault,
                                    participant: nil, activity: nil, name: nil,
                                    faultID: "drop-p3-p1-next-idr"),
                              activity("drop-idr-4000-p2-end", 4000, p2, .speechEnd),
                              activity("drop-idr-4000-p1-start", 4000, p1, .speechStart),
                              activity("drop-idr-4500-p1-continuous", 4500, p1, .continuousSpeech),
                              checkpoint("drop-idr-p3-recovered", 10500),
                              activity("drop-idr-12000-p1-end", 12000, p1, .speechEnd),
                              checkpoint("drop-idr-silence", 12500)]
        }
        return actions
    }

    private func seeded(seed: UInt64, durationMilliseconds: UInt64,
                        participants: [TopNParticipantID]) -> [TopNScenarioAction] {
        guard participants.count >= 3 else { return [] }
        let p3 = participants[2]
        var actions = Self.builtIn(.overlap, participants: participants)
            .filter { $0.atMilliseconds <= durationMilliseconds }
        let prelude: [TopNScenarioAction] = [
            .init(id: "seeded-13000-p3-leave", atMilliseconds: 13_000, kind: .leave,
                  participant: p3, activity: nil, name: nil, faultID: nil),
            .init(id: "seeded-14000-offline", atMilliseconds: 14_000, kind: .checkpoint,
                  participant: nil, activity: nil, name: "seeded-offline", faultID: nil),
            .init(id: "seeded-15000-p3-rejoin", atMilliseconds: 15_000, kind: .rejoin,
                  participant: p3, activity: nil, name: nil, faultID: nil),
            .init(id: "seeded-16000-rejoined", atMilliseconds: 16_000, kind: .checkpoint,
                  participant: nil, activity: nil, name: "seeded-rejoined", faultID: nil)
        ]
        actions.append(contentsOf: prelude.filter { $0.atMilliseconds <= durationMilliseconds })
        var state = seed
        var time: UInt64 = 17_000
        var ordinal = 0
        while time <= durationMilliseconds {
            state = state &+ 0x9E3779B97F4A7C15
            let participant = participants[Int((state ^ (state >> 30)) % UInt64(participants.count))]
            let value: TopNActivity = (state & 1) == 0 ? .speechStart : .continuousSpeech
            actions.append(.init(id: "seeded-\(ordinal)-\(participant.rawValue)-activity", atMilliseconds: time,
                                 kind: .activity, participant: participant, activity: value, name: nil, faultID: nil))
            ordinal += 1
            time += 750 + ((state >> 8) % 1751)
        }
        return actions.sorted {
            if $0.atMilliseconds != $1.atMilliseconds { return $0.atMilliseconds < $1.atMilliseconds }
            return $0.id < $1.id
        }
    }

    private func lifecycleConversation(seed: UInt64,
                                       durationMilliseconds: UInt64,
                                       participants: [TopNParticipantID]) -> [TopNScenarioAction] {
        guard participants.count >= 3 else { return [] }
        func activity(_ id: String, _ at: UInt64,
                      _ participant: TopNParticipantID,
                      _ value: TopNActivity) -> TopNScenarioAction {
            .init(id: id, atMilliseconds: at, kind: .activity,
                  participant: participant, activity: value, name: nil, faultID: nil)
        }
        var random = TopNHarnessRandom(seed: seed)
        var actions = participants.map { activity("lifecycle-conversation-0-\($0.rawValue)-end", 0, $0, .speechEnd) }
        var lastEnd = Dictionary(uniqueKeysWithValues: participants.map { ($0, UInt64(0)) })
        var time: UInt64 = 400
        var current: TopNParticipantID?
        var ordinal = 0

        for participant in participants where time + 1_100 <= durationMilliseconds {
            actions.append(activity("bootstrap-\(ordinal)-\(participant.rawValue)-start", time,
                                    participant, .speechStart))
            let overlap = random.value(in: 100...400)
            if let current {
                actions.append(activity("bootstrap-\(ordinal)-\(current.rawValue)-end", time + overlap,
                                        current, .speechEnd))
                lastEnd[current] = time + overlap
            }
            actions.append(activity("bootstrap-\(ordinal)-\(participant.rawValue)-continuous", time + overlap,
                                    participant, .continuousSpeech))
            current = participant
            ordinal += 1
            time += 1_100
        }

        var cycle = 0
        while let speaking = current, time + 5_200 <= durationMilliseconds {
            let targets = participants.filter { $0 != speaking }
            let target = targets[Int(random.next() % UInt64(targets.count))]
            let targetReady = (lastEnd[target] ?? 0) + 4_000
            let starvationEnd = max(time + random.value(in: 4_000...5_200), targetReady)

            while time + 700 < starvationEnd {
                let candidates = participants.filter { $0 != target && $0 != current }
                guard let next = candidates.randomElement(using: &random) else { break }
                let overlap = random.value(in: 100...600)
                actions.append(activity("cycle-\(cycle)-\(ordinal)-\(next.rawValue)-start", time,
                                        next, .speechStart))
                if let previous = current {
                    actions.append(activity("cycle-\(cycle)-\(ordinal)-\(previous.rawValue)-end", time + overlap,
                                            previous, .speechEnd))
                    lastEnd[previous] = time + overlap
                }
                actions.append(activity("cycle-\(cycle)-\(ordinal)-\(next.rawValue)-continuous", time + overlap,
                                        next, .continuousSpeech))
                current = next
                ordinal += 1
                let turnDuration = random.value(in: 550...1_200)
                time += max(turnDuration, overlap)
            }

            let activation = max(time, targetReady)
            let overlap = random.value(in: 100...600)
            guard activation + 1_100 <= durationMilliseconds else { break }
            actions.append(activity("reactivation-\(cycle)-\(target.rawValue)-start", activation,
                                    target, .speechStart))
            if let previous = current {
                actions.append(activity("reactivation-\(cycle)-\(previous.rawValue)-end", activation + overlap,
                                        previous, .speechEnd))
                lastEnd[previous] = activation + overlap
            }
            actions.append(activity("reactivation-\(cycle)-\(target.rawValue)-continuous", activation + overlap,
                                    target, .continuousSpeech))
            actions.append(.init(id: "reactivation-\(cycle)-checkpoint", atMilliseconds: activation + 1_000,
                                 kind: .checkpoint, participant: nil, activity: nil,
                                 name: "lifecycle-reactivation:\(target.rawValue):\(cycle)", faultID: nil))
            current = target
            time = activation + 1_100
            cycle += 1
        }
        if let current, actions.last?.atMilliseconds ?? 0 < durationMilliseconds {
            actions.append(activity("lifecycle-conversation-final-\(current.rawValue)-end",
                                    durationMilliseconds, current, .speechEnd))
        }
        return actions
    }
}

private struct TopNHarnessRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E3779B97F4A7C15
        var value = self.state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func value(in range: ClosedRange<UInt64>) -> UInt64 {
        range.lowerBound + next() % (range.upperBound - range.lowerBound + 1)
    }
}

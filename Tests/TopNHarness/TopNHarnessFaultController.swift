// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization
@testable import QuicR

enum TopNReconnectGroupDecision: Sendable {
    case normal(UInt64)
    case injected(UInt64, TopNGroupRollReason)
}

final class TopNHarnessFaultController: @unchecked Sendable {
    private struct PendingIDRDrop {
        let groupId: UInt64
        let objectId: UInt64
        var tracks: Set<String>
    }

    private struct IngressResult {
        let decision: VideoObjectIngressDecision
        let rule: TopNFaultRule?
        let shadowed: [String]
    }

    private struct State {
        var enabled: Set<String> = []
        var consumed: Set<String> = []
        var pendingIDRDrops: [String: PendingIDRDrop] = [:]
    }

    private let rules: [TopNFaultRule]
    private let recorder: TopNHarnessRecorder
    private let state = Mutex(State())

    init(rules: [TopNFaultRule], recorder: TopNHarnessRecorder) {
        self.rules = rules
        self.recorder = recorder
    }

    func enable(id: String) throws {
        guard self.rules.contains(where: { $0.id == id }) else {
            throw TopNHarnessFailure.infrastructure("unknown fault \(id)")
        }
        self.state.withLock { $0.enabled.insert(id) }
    }

    func disable(id: String) throws {
        guard self.rules.contains(where: { $0.id == id }) else {
            throw TopNHarnessFailure.infrastructure("unknown fault \(id)")
        }
        self.state.withLock { $0.enabled.remove(id) }
    }

    func ingressDecision(localParticipant: TopNParticipantID,
                         remoteParticipant: TopNParticipantID,
                         connectionGeneration: UInt64,
                         ingress: VideoObjectIngress) -> VideoObjectIngressDecision {
        let result = self.state.withLock { state -> IngressResult in
            let matching = self.rules.filter { rule in
                guard state.enabled.contains(rule.id), !state.consumed.contains(rule.id),
                      rule.localParticipant == localParticipant, rule.remoteParticipant == remoteParticipant,
                      rule.connectionGeneration.map({ $0 == connectionGeneration }) ?? true else { return false }
                if let activity = rule.activity, ingress.activity != activity.rawValue { return false }
                if let cached = rule.cached, ingress.cached != cached { return false }
                switch rule.kind {
                case .dropNextIDR:
                    guard ingress.objectId == 0 else { return false }
                    guard let pending = state.pendingIDRDrops[rule.id] else { return true }
                    return pending.groupId == ingress.groupId && pending.objectId == ingress.objectId
                case .dropLocationRange, .delayLocationRange:
                    return rule.locationRange?.contains(groupId: ingress.groupId, objectId: ingress.objectId) == true
                default: return false
                }
            }
            guard let first = matching.first else {
                return .init(decision: .deliver, rule: nil, shadowed: [])
            }
            if first.kind == .dropNextIDR {
                var pending = state.pendingIDRDrops[first.id] ?? .init(
                    groupId: ingress.groupId, objectId: ingress.objectId, tracks: [])
                pending.tracks.insert(ingress.fullTrackName.description)
                if pending.tracks.count == TopNVideoQuality.allCases.count {
                    state.pendingIDRDrops.removeValue(forKey: first.id)
                    state.consumed.insert(first.id)
                } else {
                    state.pendingIDRDrops[first.id] = pending
                }
            }
            let shadowed = matching.dropFirst().map(\.id)
            switch first.kind {
            case .dropNextIDR, .dropLocationRange:
                return .init(decision: .drop(reason: first.id), rule: first, shadowed: shadowed)
            case .delayLocationRange:
                return .init(decision: .delay(seconds: first.delaySeconds ?? 0, reason: first.id),
                             rule: first, shadowed: shadowed)
            default:
                return .init(decision: .deliver, rule: nil, shadowed: [])
            }
        }
        if let rule = result.rule {
            self.recordFault(rule: rule, local: localParticipant, remote: remoteParticipant,
                             generation: connectionGeneration, ingress: ingress,
                             disposition: String(describing: result.decision), shadowed: result.shadowed)
        }
        return result.decision
    }

    func shouldSuppressNextNGR(publisher: TopNParticipantID,
                               connectionGeneration: UInt64) -> Bool {
        let rule = self.state.withLock { state -> TopNFaultRule? in
            guard let rule = self.rules.first(where: {
                $0.kind == .suppressNextNGR && $0.remoteParticipant == publisher &&
                    $0.localParticipant == nil && state.enabled.contains($0.id) &&
                    !state.consumed.contains($0.id) &&
                    ($0.connectionGeneration == nil || $0.connectionGeneration == connectionGeneration)
            }) else { return nil }
            state.consumed.insert(rule.id)
            return rule
        }
        if let rule {
            self.recorder.recordHarnessEvent(client: publisher, connectionGeneration: connectionGeneration,
                                             stage: .faultApplied,
                                             details: .init(reason: "suppressNextNGR", faultID: rule.id))
            return true
        }
        return false
    }

    func reconnectGroupDecision(publisher: TopNParticipantID,
                                connectionGeneration: UInt64,
                                previousSuccessfulGroupId: UInt64,
                                normalGroupId: UInt64) throws -> TopNReconnectGroupDecision {
        let rule = self.state.withLock { state -> TopNFaultRule? in
            guard let rule = self.rules.first(where: {
                ($0.kind == .reuseGroupBaseOnNextRejoin || $0.kind == .regressGroupBaseOnNextRejoin) &&
                    $0.remoteParticipant == publisher && $0.localParticipant == nil &&
                    state.enabled.contains($0.id) && !state.consumed.contains($0.id) &&
                    ($0.connectionGeneration == nil || $0.connectionGeneration == connectionGeneration)
            }) else { return nil }
            state.consumed.insert(rule.id)
            return rule
        }
        guard let rule else { return .normal(normalGroupId) }
        switch rule.kind {
        case .reuseGroupBaseOnNextRejoin:
            return .injected(previousSuccessfulGroupId, .injectedReuse)
        case .regressGroupBaseOnNextRejoin:
            guard previousSuccessfulGroupId > 0 else {
                throw TopNHarnessFailure.infrastructure("cannot regress group base zero")
            }
            return .injected(previousSuccessfulGroupId - 1, .injectedRegression)
        default:
            return .normal(normalGroupId)
        }
    }

    private func recordFault(rule: TopNFaultRule, local: TopNParticipantID,
                             remote: TopNParticipantID, generation: UInt64,
                             ingress: VideoObjectIngress, disposition: String,
                             shadowed: [String]) {
        self.recorder.recordHarnessEvent(client: local, connectionGeneration: generation,
                                         remoteParticipant: remote, groupId: ingress.groupId,
                                         objectId: ingress.objectId, stage: .faultApplied,
                                         details: .init(reason: disposition, faultID: rule.id,
                                                        shadowedFaultIDs: shadowed.isEmpty ? nil : shadowed))
    }
}

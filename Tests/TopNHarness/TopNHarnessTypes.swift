// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
@testable import QuicR

struct TopNParticipantID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

extension TopNParticipantID {
    var isValidHarnessIdentifier: Bool {
        guard self.rawValue.first == "p",
              let value = UInt16(self.rawValue.dropFirst()), value > 0 else { return false }
        return self.rawValue == "p\(value)"
    }
}

enum TopNActivity: UInt8, Codable, CaseIterable, Sendable {
    case speechEnd = 0
    case continuousSpeech = 1
    case speechStart = 2
}

enum TopNBuiltInScenario: String, Codable, Sendable {
    case orderly
    case overlap
    case lifecycle
    case dropIDRRecovery = "drop-idr-recovery"
}

struct TopNScenarioSelection: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case builtIn, seeded, roundRobin, lifecycleConversation, replay
    }

    let kind: Kind
    let builtIn: TopNBuiltInScenario?
    let seed: UInt64?
    let durationMilliseconds: UInt64?
    let replayPath: String?

    func validated() throws -> Self {
        switch self.kind {
        case .builtIn:
            guard self.builtIn != nil, self.seed == nil,
                  self.durationMilliseconds == nil, self.replayPath == nil else {
                throw TopNHarnessFailure.infrastructure("builtIn scenario selection has invalid fields")
            }
        case .seeded, .lifecycleConversation:
            guard self.builtIn == nil, self.seed != nil,
                  let duration = self.durationMilliseconds, duration > 0,
                  self.replayPath == nil else {
                throw TopNHarnessFailure.infrastructure("seeded scenario selection has invalid fields")
            }
        case .roundRobin:
            guard self.builtIn == nil, self.seed == nil,
                  let duration = self.durationMilliseconds, duration > 0,
                  self.replayPath == nil else {
                throw TopNHarnessFailure.infrastructure("roundRobin scenario selection has invalid fields")
            }
        case .replay:
            guard self.builtIn == nil, self.seed == nil,
                  self.durationMilliseconds == nil,
                  let path = self.replayPath, !path.isEmpty,
                  URL(fileURLWithPath: path).isFileURL,
                  path.hasPrefix("/") else {
                throw TopNHarnessFailure.infrastructure("replay scenario selection has invalid fields")
            }
        }
        return self
    }
}

struct TopNScenarioAction: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case activity, leave, rejoin, checkpoint, enableFault, disableFault
    }

    let id: String
    let atMilliseconds: UInt64
    let kind: Kind
    let participant: TopNParticipantID?
    let activity: TopNActivity?
    let name: String?
    let faultID: String?
}

struct TopNScenario: Codable, Sendable {
    let version: Int
    let name: String
    let seed: UInt64?
    let participants: [TopNParticipantID]
    let actions: [TopNScenarioAction]
}

struct TopNLocationRange: Codable, Equatable, Sendable {
    let firstGroupId: UInt64
    let firstObjectId: UInt64
    let lastGroupId: UInt64
    let lastObjectId: UInt64
}

extension TopNLocationRange {
    func contains(groupId: UInt64, objectId: UInt64) -> Bool {
        let location = (groupId, objectId)
        return location >= (self.firstGroupId, self.firstObjectId) &&
            location <= (self.lastGroupId, self.lastObjectId)
    }
}

struct TopNFaultRule: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case dropNextIDR
        case dropLocationRange
        case delayLocationRange
        case suppressNextNGR
        case reuseGroupBaseOnNextRejoin
        case regressGroupBaseOnNextRejoin
    }

    let id: String
    let kind: Kind
    let localParticipant: TopNParticipantID?
    let remoteParticipant: TopNParticipantID
    let connectionGeneration: UInt64?
    let locationRange: TopNLocationRange?
    let delaySeconds: TimeInterval?
    let activity: TopNActivity?
    let cached: Bool?
}

extension TopNFaultRule {
    func validated(participants: Set<TopNParticipantID>,
                   lifecycleSeconds: TimeInterval) throws {
        guard !self.id.isEmpty, participants.contains(self.remoteParticipant) else {
            throw TopNHarnessFailure.infrastructure("fault \(self.id) has an invalid ID or remote participant")
        }
        guard self.connectionGeneration.map({ $0 > 0 }) ?? true else {
            throw TopNHarnessFailure.infrastructure("fault \(self.id) has an invalid connection generation")
        }
        if let local = self.localParticipant {
            guard participants.contains(local), local != self.remoteParticipant else {
                throw TopNHarnessFailure.infrastructure("fault \(self.id) has an invalid local participant")
            }
        }
        switch self.kind {
        case .dropNextIDR:
            guard self.localParticipant != nil, self.locationRange == nil, self.delaySeconds == nil else {
                throw TopNHarnessFailure.infrastructure("dropNextIDR fault \(self.id) has invalid fields")
            }
        case .dropLocationRange:
            guard self.localParticipant != nil, self.validRange, self.delaySeconds == nil else {
                throw TopNHarnessFailure.infrastructure("dropLocationRange fault \(self.id) has invalid fields")
            }
        case .delayLocationRange:
            guard self.localParticipant != nil, self.validRange,
                  let delay = self.delaySeconds, delay > 0, delay.isFinite,
                  delay <= lifecycleSeconds else {
                throw TopNHarnessFailure.infrastructure("delayLocationRange fault \(self.id) has invalid fields")
            }
        case .suppressNextNGR, .reuseGroupBaseOnNextRejoin, .regressGroupBaseOnNextRejoin:
            guard self.localParticipant == nil, self.locationRange == nil, self.delaySeconds == nil,
                  self.activity == nil, self.cached == nil else {
                throw TopNHarnessFailure.infrastructure("publisher fault \(self.id) has invalid fields")
            }
        }
    }

    private var validRange: Bool {
        guard let range = self.locationRange else { return false }
        return (range.firstGroupId, range.firstObjectId) <= (range.lastGroupId, range.lastObjectId)
    }
}

struct TopNJoinPolicy: Codable, Equatable, Sendable {
    enum Name: String, Codable, Sendable { case ngr, fetch, wait, mixed }
    let name: Name
    let fetchUpperThresholdSeconds: TimeInterval
    let newGroupUpperThresholdSeconds: TimeInterval

    static let ngr = Self(name: .ngr, fetchUpperThresholdSeconds: 0, newGroupUpperThresholdSeconds: 5)
    static let fetch = Self(name: .fetch, fetchUpperThresholdSeconds: 5, newGroupUpperThresholdSeconds: 5)
    static let wait = Self(name: .wait, fetchUpperThresholdSeconds: 0, newGroupUpperThresholdSeconds: 0)
    static let mixed = Self(name: .mixed, fetchUpperThresholdSeconds: 1, newGroupUpperThresholdSeconds: 4)
}

struct TopNHarnessDeadlines: Codable, Sendable {
    let mediaConvergenceSeconds: TimeInterval
    let livenessSeconds: TimeInterval
    let maxDisplayGapSeconds: TimeInterval
    let lifecycleSeconds: TimeInterval
    let diagnosticDrainSeconds: TimeInterval
}

struct TopNHarnessConfiguration: Codable, Sendable {
    let version: Int
    let relayURI: String
    let artifactDirectory: String
    let meetingID: String
    let participants: [TopNParticipantID]
    let topN: Int
    let filterTimeoutMilliseconds: UInt64
    let joinPolicy: TopNJoinPolicy
    let scenario: TopNScenarioSelection
    let deadlines: TopNHarnessDeadlines
    let faults: [TopNFaultRule]
    let enableQlog: Bool

    static func load(path: String) throws -> Self {
        let configURL = URL(fileURLWithPath: path).standardizedFileURL
        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            let configuration = try decoder.decode(Self.self, from: data)
            return try configuration.validated()
        } catch let error as DecodingError {
            throw TopNHarnessFailure.infrastructure("Could not decode \(configURL.path): \(error)")
        } catch let error as TopNHarnessFailure {
            throw error
        } catch {
            throw TopNHarnessFailure.infrastructure("Could not load \(configURL.path): \(error.localizedDescription)")
        }
    }

    func validated() throws -> Self {
        guard self.version == 1 else { throw TopNHarnessFailure.infrastructure("configuration version must be 1") }
        guard URL(string: self.relayURI) != nil, !self.relayURI.isEmpty else {
            throw TopNHarnessFailure.infrastructure("relayURI is invalid")
        }
        guard self.artifactDirectory.hasPrefix("/") else {
            throw TopNHarnessFailure.infrastructure("artifactDirectory must be absolute")
        }
        guard self.participants.count >= 3, self.participants.count <= Int(UInt16.max),
              Set(self.participants).count == self.participants.count,
              self.participants.allSatisfy(\.isValidHarnessIdentifier) else {
            throw TopNHarnessFailure.infrastructure("participants must be unique and contain 3...65535 entries")
        }
        guard self.topN > 0, self.topN < self.participants.count else {
            throw TopNHarnessFailure.infrastructure("topN must be in 1..<participants.count")
        }
        guard self.filterTimeoutMilliseconds > 0 else {
            throw TopNHarnessFailure.infrastructure("filter timeout must be positive")
        }
        let deadlineValues = [self.deadlines.mediaConvergenceSeconds, self.deadlines.livenessSeconds,
                              self.deadlines.maxDisplayGapSeconds, self.deadlines.lifecycleSeconds,
                              self.deadlines.diagnosticDrainSeconds]
        guard deadlineValues.allSatisfy({ $0 > 0 && $0.isFinite }) else {
            throw TopNHarnessFailure.infrastructure("all deadlines must be positive and finite")
        }
        _ = try self.scenario.validated()
        var faultIDs = Set<String>()
        for fault in self.faults {
            guard faultIDs.insert(fault.id).inserted else {
                throw TopNHarnessFailure.infrastructure("fault IDs must be unique")
            }
            try fault.validated(participants: Set(self.participants),
                                lifecycleSeconds: self.deadlines.lifecycleSeconds)
        }
        return self
    }
}

enum TopNHarnessOutcomeClass: String, Codable, Sendable {
    case passed, infrastructure, transport, relayConvergence, clientMedia
}

enum TopNHarnessStage: String, Codable, Sendable {
    case scenarioAction, checkpoint, faultEnabled, faultDisabled, faultApplied
    case publishOffered, publishAccepted, publishRejected
    case publicationStatus, publishedObject, connectionLeft, connectionRejoined
    case subscriptionStatus, objectReceived, objectUsable, objectRejected
    case handlerCreated, handlerStopped, joinDecision, fetchRequested
    case fetchStatus, fetchCompleted, newGroupRequested, jitterAdmitted, jitterRejected
    case nameGate, decoderSubmitted, decoderOutput, decoderError
    case simulreceiveCandidate, simulreceiveSelected, displayEnqueued, displayPresented, displayError
}

struct TopNHarnessEventDetails: Codable, Sendable {
    let status: String?
    let statusCode: UInt64?
    let reason: String?
    let faultID: String?
    let joinStrategy: String?
    let rollReason: String?
    let cached: Bool?
    let accepted: Bool?
    let displayed: Bool?
    let startObjectId: UInt64?
    let endObjectId: UInt64?
    let previousGroupId: UInt64?
    let previousObjectId: UInt64?
    let presentationSeconds: TimeInterval?
    let delaySeconds: TimeInterval?
    let shadowedFaultIDs: [String]?

    init(status: String? = nil, statusCode: UInt64? = nil, reason: String? = nil,
         faultID: String? = nil, joinStrategy: String? = nil, rollReason: String? = nil,
         cached: Bool? = nil, accepted: Bool? = nil, displayed: Bool? = nil,
         startObjectId: UInt64? = nil, endObjectId: UInt64? = nil,
         previousGroupId: UInt64? = nil, previousObjectId: UInt64? = nil,
         presentationSeconds: TimeInterval? = nil, delaySeconds: TimeInterval? = nil,
         shadowedFaultIDs: [String]? = nil) {
        self.status = status
        self.statusCode = statusCode
        self.reason = reason
        self.faultID = faultID
        self.joinStrategy = joinStrategy
        self.rollReason = rollReason
        self.cached = cached
        self.accepted = accepted
        self.displayed = displayed
        self.startObjectId = startObjectId
        self.endObjectId = endObjectId
        self.previousGroupId = previousGroupId
        self.previousObjectId = previousObjectId
        self.presentationSeconds = presentationSeconds
        self.delaySeconds = delaySeconds
        self.shadowedFaultIDs = shadowedFaultIDs
    }
}

struct TopNHarnessRecordedEvent: Codable, Sendable {
    let ordinal: UInt64
    let elapsedMilliseconds: Double
    let wallClock: Date
    let scheduledMilliseconds: Double?
    let client: TopNParticipantID
    let connectionGeneration: UInt64
    let remoteParticipant: TopNParticipantID?
    let handlerGeneration: UInt64?
    let renderEpoch: UInt64?
    let groupId: UInt64?
    let subgroupId: UInt64?
    let objectId: UInt64?
    let stage: TopNHarnessStage
    let activity: UInt8?
    let actionID: String?
    let details: TopNHarnessEventDetails?
}

struct TopNHarnessFailureDetail: Codable, Sendable {
    let outcomeClass: TopNHarnessOutcomeClass
    let message: String
    let subscriber: TopNParticipantID?
    let publisher: TopNParticipantID?
    let connectionGeneration: UInt64?
    let handlerGeneration: UInt64?
    let renderEpoch: UInt64?
    let groupId: UInt64?
    let objectId: UInt64?
    let lastSuccessfulStage: TopNHarnessStage?
}

struct TopNHarnessFailure: LocalizedError, Sendable {
    let detail: TopNHarnessFailureDetail

    static func infrastructure(_ message: String) -> Self {
        .init(detail: .init(outcomeClass: .infrastructure, message: message,
                            subscriber: nil, publisher: nil, connectionGeneration: nil,
                            handlerGeneration: nil, renderEpoch: nil, groupId: nil,
                            objectId: nil, lastSuccessfulStage: nil))
    }

    var errorDescription: String? { self.detail.message }
}

struct TopNHarnessSummary: Codable, Sendable {
    let version: Int
    let outcomeClass: TopNHarnessOutcomeClass
    let startedAt: Date
    let endedAt: Date
    let scenarioName: String
    let seed: UInt64?
    let joinPolicy: TopNJoinPolicy
    let checkpointsExecuted: Int
    let checkpointsPassed: Int
    let failure: TopNHarnessFailureDetail?
}

struct TopNExpectedView: Equatable, Sendable {
    let required: Set<TopNParticipantID>
    let allowed: Set<TopNParticipantID>
    let expectedCount: Int
}

struct TopNStageProgress: Sendable {
    var received: [Ticks] = []
    var usable: [Ticks] = []
    var decoded: [Ticks] = []
    var selected: [Ticks] = []
    var displayed: [Ticks] = []
}

struct TopNOracleViolation: Error, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case selfDelivery, offlineDelivery, outsideAllowedSet, tooFewDelivered, tooManyDelivered
        case missingRequiredTrack, noUsableObject, noDecoderOutput, noSelection, noDisplay
        case displayNotSustained, unhealthyConnection
        case missingInactiveCleanup, missingReactivation, staleGenerationDisplay, noPresentedFrame
    }
    let code: Code
    let subscriber: TopNParticipantID
    let publisher: TopNParticipantID?
}

extension VideoPipelineEvent.Kind {
    var topNStage: TopNHarnessStage {
        switch self {
        case .subscriptionStatus: .subscriptionStatus
        case .objectReceived: .objectReceived
        case .objectUsable: .objectUsable
        case .objectRejected: .objectRejected
        case .handlerCreated: .handlerCreated
        case .handlerStopped: .handlerStopped
        case .joinDecision: .joinDecision
        case .fetchRequested: .fetchRequested
        case .fetchStatus: .fetchStatus
        case .fetchCompleted: .fetchCompleted
        case .newGroupRequested: .newGroupRequested
        case .jitterAdmitted: .jitterAdmitted
        case .jitterRejected: .jitterRejected
        case .nameGate: .nameGate
        case .decoderSubmitted: .decoderSubmitted
        case .decoderOutput: .decoderOutput
        case .decoderError: .decoderError
        case .simulreceiveCandidate: .simulreceiveCandidate
        case .simulreceiveSelected: .simulreceiveSelected
        case .displayEnqueued: .displayEnqueued
        case .displayError: .displayError
        }
    }
}

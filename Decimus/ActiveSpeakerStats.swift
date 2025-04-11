// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

actor ActiveSpeakerStats {
    enum Error: Swift.Error {
        case missing
    }

    struct Record {
        let currentState: CurrentState
        let detected: Date?
        let set: Date?
        let enqueued: Date?
    }

    struct Result {
        let detected: Date?
        let set: Date?
        let enqueued: Date

        init(_ record: Record) {
            self.detected = record.detected
            self.set = record.set
            self.enqueued = record.enqueued!
        }
    }

    enum CurrentState: CustomStringConvertible {
        case inactive
        case audioDetected
        case activeSpeakerSet
        case imageEnqueued

        var description: String {
            switch self {
            case .inactive:
                "Inactive"
            case .audioDetected:
                "Audio Detected"
            case .activeSpeakerSet:
                "Active Speaker"
            case .imageEnqueued:
                "Image Enqueued"
            }
        }
    }

    typealias Identifier = ParticipantId

    private var participants: [Identifier: Record] = [:]
    private let measurement: MeasurementRegistration<ActiveSpeakerStatsMeasurement>?
    private var currentState: [ParticipantId: CurrentState] = [:]
    private var reportTask: Task<Void, Never>?

    init(_ submitter: MetricsSubmitter?) {
        guard let submitter = submitter else {
            self.measurement = nil
            return
        }
        self.measurement = .init(measurement: .init(), submitter: submitter)
        self.reportTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let now = Date.now
                if let self = self {
                    for participant in await self.participants {
                        await self.reportCurrentState(identifier: participant.key,
                                                      state: participant.value.currentState,
                                                      now: now)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func reportCurrentState(identifier: Identifier, state: CurrentState, now: Date) async {
        switch state {
        case .inactive:
            await self.measurement?.measurement.inactiveSet(identifier: identifier, timestamp: now)
        case .audioDetected:
            await self.measurement?.measurement.audioDetected(identifier: identifier, timestamp: now)
        case .activeSpeakerSet:
            await self.measurement?.measurement.activeSet(identifier: identifier, timestamp: now)
        case .imageEnqueued:
            await self.measurement?.measurement.imageEnqueued(identifier: identifier, timestamp: now)
        }
    }

    /// Audio from this participant was just detected.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the audio was detected.
    func audioDetected(_ identifier: Identifier, when: Date) async {
        let existing = self.participants[identifier]
        let state = await self.stateTransition(identifier: identifier,
                                               from: existing?.currentState,
                                               to: .audioDetected, when: when)
        self.participants[identifier] = .init(currentState: state,
                                              detected: existing?.detected ?? when,
                                              set: existing?.set,
                                              enqueued: existing?.enqueued)
    }

    /// This speaker was just set to active.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the speaker was set to active.
    func activeSpeakerSet(_ identifier: Identifier, when: Date) async {
        let record = self.participants[identifier]
        let state = await self.stateTransition(identifier: identifier,
                                               from: record?.currentState,
                                               to: .activeSpeakerSet, when: when)
        self.participants[identifier] = .init(currentState: state,
                                              detected: record?.detected,
                                              set: record?.set ?? when,
                                              enqueued: record?.enqueued)
        await self.measurement?.measurement.activeSet(identifier: identifier, timestamp: when)
    }

    /// This speaker's video was enqueued/displayed.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the video was enqueued/displayed.
    func imageEnqueued(_ identifier: Identifier, when: Date) async -> Result {
        let record = self.participants[identifier]
        let state = await self.stateTransition(identifier: identifier,
                                               from: record?.currentState,
                                               to: .imageEnqueued, when: when)
        let updated = Record(currentState: state,
                             detected: record?.detected,
                             set: record?.set,
                             enqueued: record?.enqueued ?? when)
        self.participants[identifier] = updated
        return .init(updated)
    }

    /// This participant was set inactive.
    /// - Parameter identifier: The participant.
    func remove(_ identifier: Identifier, when: Date) async {
        let record = self.participants[identifier]
        _ = await self.stateTransition(identifier: identifier, from: record?.currentState, to: .inactive, when: when)
        self.participants.removeValue(forKey: identifier)
    }

    private func stateTransition(identifier: Identifier,
                                 from: CurrentState?,
                                 to: CurrentState,
                                 when: Date) async -> CurrentState {
        guard let from else { return to }
        let result = switch from {
        case .inactive:
            to
        case .audioDetected:
            to
        case .activeSpeakerSet:
            to == .audioDetected ? .activeSpeakerSet : to
        case .imageEnqueued:
            switch to {
            case .activeSpeakerSet:
                CurrentState.imageEnqueued
            case .audioDetected:
                CurrentState.imageEnqueued
            default:
                to
            }
        }
        await self.reportCurrentState(identifier: identifier, state: result, now: when)
        return result
    }
}

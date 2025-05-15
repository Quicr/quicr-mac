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
        let dropped: Date?
        let received: Date?
        let enqueued: Date?
    }

    struct Result {
        let detected: Date?
        let set: Date?
        let dropped: Date?
        let received: Date
        let enqueued: Date

        init(_ record: Record) {
            self.detected = record.detected
            self.set = record.set
            self.dropped = record.dropped
            self.received = record.received!
            self.enqueued = record.enqueued!
        }
    }

    enum CurrentState: CustomStringConvertible {
        case inactive
        case audioDetected
        case activeSpeakerSet
        case dataDropped
        case dataReceived
        case imageEnqueued

        var description: String {
            switch self {
            case .inactive:
                "Inactive"
            case .audioDetected:
                "Audio"
            case .activeSpeakerSet:
                "Active Speaker"
            case .dataDropped:
                "Data Dropped"
            case .dataReceived:
                "Data Received"
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
                        await self.measurement?.measurement.record(identifier: participant.key,
                                                                   timestamp: now,
                                                                   event: participant.value.currentState)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
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
                                              dropped: existing?.dropped,
                                              received: existing?.received,
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
                                              dropped: record?.dropped,
                                              received: record?.received,
                                              enqueued: record?.enqueued)
    }

    /// This speaker's encoded video was received, but it was dropped.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the video was received.
    func dataDropped(_ identifier: Identifier, when: Date) async {
        let record = self.participants[identifier]
        let state = await self.stateTransition(identifier: identifier,
                                               from: record?.currentState,
                                               to: .dataDropped,
                                               when: when)
        self.participants[identifier] = .init(currentState: state,
                                              detected: record?.detected,
                                              set: record?.set,
                                              dropped: record?.dropped ?? when,
                                              received: record?.received,
                                              enqueued: record?.enqueued)
    }

    /// This speaker's encoded video was received.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the video was received.
    func dataReceived(_ identifier: Identifier, when: Date) async {
        let record = self.participants[identifier]
        let state = await self.stateTransition(identifier: identifier,
                                               from: record?.currentState,
                                               to: .dataReceived,
                                               when: when)
        self.participants[identifier] = .init(currentState: state,
                                              detected: record?.detected,
                                              set: record?.set,
                                              dropped: record?.dropped,
                                              received: record?.received ?? when,
                                              enqueued: record?.enqueued)
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
                             dropped: record?.dropped,
                             received: record?.received,
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

    // swiftlint:disable cyclomatic_complexity function_body_length
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
            switch to {
            case .audioDetected:
                CurrentState.activeSpeakerSet
            default:
                to
            }
        case .dataDropped:
            switch to {
            case .activeSpeakerSet:
                CurrentState.dataDropped
            case .audioDetected:
                CurrentState.dataDropped
            default:
                to
            }
        case .dataReceived:
            switch to {
            case .activeSpeakerSet:
                CurrentState.dataReceived
            case .audioDetected:
                CurrentState.dataReceived
            case .dataDropped:
                CurrentState.dataReceived
            default:
                to
            }
        case .imageEnqueued:
            switch to {
            case .activeSpeakerSet:
                CurrentState.imageEnqueued
            case .audioDetected:
                CurrentState.imageEnqueued
            case .dataReceived:
                CurrentState.imageEnqueued
            case .dataDropped:
                CurrentState.imageEnqueued
            default:
                to
            }
        }
        await self.measurement?.measurement.record(identifier: identifier,
                                                   timestamp: when,
                                                   event: result)
        return result
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}

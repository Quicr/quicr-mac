// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

actor ActiveSpeakerStats {
    enum Error: Swift.Error {
        case missing
    }

    struct Record {
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

    typealias Identifier = ParticipantId

    private var participants: [Identifier: Record] = [:]
    private let measurement: MeasurementRegistration<ActiveSpeakerStatsMeasurement>?

    init(_ submitter: MetricsSubmitter?) {
        guard let submitter = submitter else {
            self.measurement = nil
            return
        }
        self.measurement = .init(measurement: .init(), submitter: submitter)
    }

    /// Audio from this participant was just detected.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the audio was detected.
    func audioDetected(_ identifier: Identifier, when: Date) async {
        let existing = self.participants[identifier]
        self.participants[identifier] = .init(detected: existing?.detected ?? when,
                                              set: existing?.set,
                                              enqueued: existing?.enqueued)
        await self.measurement?.measurement.audioDetected(identifier: identifier, timestamp: when)
    }

    /// This speaker was just set to active.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the speaker was set to active.
    func activeSpeakerSet(_ identifier: Identifier, when: Date) async {
        let record = self.participants[identifier]
        self.participants[identifier] = .init(detected: record?.detected,
                                              set: record?.set ?? when,
                                              enqueued: record?.enqueued)
        await self.measurement?.measurement.activeSet(identifier: identifier, timestamp: when)
    }

    /// This speaker's video was enqueued/displayed.
    /// - Parameter identifier: The participant.
    /// - Parameter when: The point in time the video was enqueued/displayed.
    func imageEnqueued(_ identifier: Identifier, when: Date) async -> Result {
        let record = self.participants[identifier]
        let updated = Record(detected: record?.detected,
                             set: record?.set,
                             enqueued: record?.enqueued ?? when)
        self.participants[identifier] = updated
        await self.measurement?.measurement.imageEnqueued(identifier: identifier, timestamp: when)
        return .init(updated)
    }

    /// This participant was set inactive.
    /// - Parameter identifier: The participant.
    func remove(_ identifier: Identifier, when: Date) async {
        await self.measurement?.measurement.inactiveSet(identifier: identifier, timestamp: when)
        self.participants.removeValue(forKey: identifier)
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

actor ActiveSpeakerStats {
    enum Error: Swift.Error {
        case missing
    }

    private struct Record {
        let detected: Date?
        let set: Date?
        let enqueued: Date?
    }

    struct Result {
        let detected: Date?
        let set: Date?
        let enqueued: Date

        fileprivate init(_ record: Record) {
            self.detected = record.detected
            self.set = record.set
            self.enqueued = record.enqueued!
        }
    }

    typealias Identifier = ParticipantId

    private var participants: [Identifier: Record] = [:]

    func audioDetected(_ identifier: Identifier, when: Date) {
        let existing = self.participants[identifier]
        self.participants[identifier] = .init(detected: existing?.detected ?? when,
                                              set: existing?.set,
                                              enqueued: existing?.enqueued)
    }

    func activeSpeakerSet(_ identifier: Identifier, when: Date) {
        let record = self.participants[identifier]
        self.participants[identifier] = .init(detected: record?.detected,
                                              set: record?.set ?? when,
                                              enqueued: record?.enqueued)
    }

    func imageEnqueued(_ identifier: Identifier, when: Date) -> Result {
        let record = self.participants[identifier]
        let updated = Record(detected: record?.detected,
                             set: record?.set,
                             enqueued: record?.enqueued ?? when)
        self.participants[identifier] = updated
        return .init(updated)
    }

    func remove(_ identifier: Identifier) {
        self.participants.removeValue(forKey: identifier)
    }
}

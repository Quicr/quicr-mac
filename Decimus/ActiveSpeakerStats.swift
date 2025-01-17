// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

actor ActiveSpeakerStats {
    enum Error: Swift.Error {
        case missing
    }

    // TODO: What type should this be? ParticipantId?
    typealias Identifier = String

    private var participants: [Identifier: Date] = [:]

    func audioDetected(_ identifier: Identifier, when: Date) {
        self.participants[identifier] = when
    }

    func activeSpeakerSet(_ identifier: Identifier, when: Date) throws -> TimeInterval {
        try self.calc(identifier, when: when)
    }

    func imageEnqueued(_ identifier: Identifier, when: Date) throws -> TimeInterval {
        try self.calc(identifier, when: when)
    }

    private func calc(_ identifier: Identifier, when: Date) throws -> TimeInterval {
        guard let insertDate = self.participants[identifier] else {
            throw Error.missing
        }
        return when.timeIntervalSince(insertDate)
    }

    func remove(_ identifier: Identifier) {
        self.participants.removeValue(forKey: identifier)
    }
}

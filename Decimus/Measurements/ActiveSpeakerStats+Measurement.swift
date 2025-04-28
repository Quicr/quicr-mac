// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension ActiveSpeakerStats {
    actor ActiveSpeakerStatsMeasurement: Measurement {
        let id = UUID()
        var name: String = "ActiveSpeaker"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        func record(identifier: ParticipantId, timestamp: Date, event: CurrentState) {
            record(field: "events",
                   value: event.description as AnyObject,
                   timestamp: timestamp,
                   tags: ["participant": "\(identifier.participantId)"])
        }
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension ActiveSpeakerStats {
    actor ActiveSpeakerStatsMeasurement: Measurement {
        let id = UUID()
        var name: String = "ActiveSpeaker"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        func audioDetected(identifier: ParticipantId, timestamp: Date) {
            record(field: "events",
                   value: "Audio" as AnyObject,
                   timestamp: timestamp,
                   tags: ["participant": "\(identifier.participantId)"])
        }

        func activeSet(identifier: ParticipantId, timestamp: Date) {
            record(field: "events",
                   value: "Active Speaker" as AnyObject,
                   timestamp: timestamp,
                   tags: ["participant": "\(identifier.participantId)"])
        }

        func imageEnqueued(identifier: ParticipantId, timestamp: Date) {
            record(field: "events",
                   value: "Image Enqueued" as AnyObject,
                   timestamp: timestamp,
                   tags: ["participant": "\(identifier.participantId)"])
        }

        func inactiveSet(identifier: ParticipantId, timestamp: Date) {
            record(field: "events",
                   value: "Inactive" as AnyObject,
                   timestamp: timestamp,
                   tags: ["participant": "\(identifier.participantId)"])
        }
    }
}

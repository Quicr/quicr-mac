// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension ActiveSpeakerStats {
    actor ActiveSpeakerStatsMeasurement: Measurement {
        let id = UUID()
        var name: String = "ActiveSpeaker"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        func audioDetected(identifier: ParticipantId, timestamp: Date) {
            record(field: "audioDetected", value: identifier.participantId as AnyObject, timestamp: timestamp)
        }

        func activeSet(identifier: ParticipantId, timestamp: Date) {
            record(field: "activeSet", value: identifier.participantId as AnyObject, timestamp: timestamp)
        }

        func imageEnqueued(identifier: ParticipantId, timestamp: Date) {
            record(field: "enqueued", value: identifier.participantId as AnyObject, timestamp: timestamp)
        }

        func inactiveSet(identifier: ParticipantId, timestamp: Date) {
            record(field: "inactive", value: identifier.participantId as AnyObject, timestamp: timestamp)
        }
    }
}

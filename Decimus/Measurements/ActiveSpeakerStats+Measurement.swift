// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension ActiveSpeakerStats {
    final class ActiveSpeakerStatsMeasurement: MeasurementBase {
        init() {
            super.init(name: "ActiveSpeaker")
        }

        func record(identifier: ParticipantId, timestamp: Date, event: CurrentState) {
            record(field: "events",
                   value: event.description as AnyObject,
                   timestamp: timestamp,
                   tags: ["participant": "\(identifier.participantId)"])
        }
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Measurement actor for activity_transition InfluxDB measurement.
/// One point emitted per audio activity state transition (after rate-limiting).
actor ActivityTransitionMeasurement: Measurement {
    let id = UUID()
    var name: String = "activity_transition"
    var fields: Fields = [:]
    var tags: [String: String] = [:]

    private var sequence: UInt64 = 0

    /// Record an activity state transition.
    /// - Parameters:
    ///   - participant: The local participant ID string.
    ///   - direction: "active" or "inactive"
    ///   - timestamp: When the transition occurred (after AudioActivityStateMachine rate-limiting)
    func record(participant: String, direction: String, timestamp: Date) {
        self.sequence += 1
        record(field: "sequence",
               value: self.sequence as AnyObject,
               timestamp: timestamp,
               tags: ["participant": participant, "direction": direction])
    }
}

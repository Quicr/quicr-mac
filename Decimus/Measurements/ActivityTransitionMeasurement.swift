// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization

final class ActivityTransitionMeasurement: MeasurementBase {
    private let sequence = Atomic<UInt64>(0)

    init() {
        super.init(name: "activity_transition")
    }

    func record(participant: String, direction: String, timestamp: Date) {
        let val = sequence.wrappingAdd(1, ordering: .relaxed).newValue
        record(field: "sequence",
               value: val as AnyObject,
               timestamp: timestamp,
               tags: ["participant": participant, "direction": direction])
    }
}

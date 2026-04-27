// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

extension CaptureManager {
    final class CaptureManagerMeasurement: MetricsMeasurement {
        let storage = MeasurementStorage()
        let name = "CaptureManager"
        let tags: [String: String] = [:]
        private let capturedFrames = Atomic<UInt64>(0)
        private let dropped = Atomic<UInt64>(0)

        func droppedFrame(timestamp: Date?) {
            let val = dropped.wrappingAdd(1, ordering: .relaxed).newValue
            record(field: "droppedFrames", value: val as AnyObject, timestamp: timestamp)
        }

        func capturedFrame(frameTimestamp: TimeInterval, metricsTimestamp: Date?) {
            let val = capturedFrames.wrappingAdd(1, ordering: .relaxed).newValue
            record(field: "capturedFrames", value: val as AnyObject, timestamp: metricsTimestamp)
            if let metricsTimestamp = metricsTimestamp {
                record(field: "timestamp", value: frameTimestamp as AnyObject, timestamp: metricsTimestamp)
            }
        }

        func pressureStateChanged(level: Int, metricsTimestamp: Date) {
            record(field: "pressureState", value: level as AnyObject, timestamp: metricsTimestamp)
        }
    }
}

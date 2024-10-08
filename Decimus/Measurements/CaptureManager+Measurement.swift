// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension CaptureManager {
    actor CaptureManagerMeasurement: Measurement {
        let id = UUID()
        var name: String = "CaptureManager"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var capturedFrames: UInt64 = 0
        private var dropped: UInt64 = 0

        func droppedFrame(timestamp: Date?) {
            self.dropped += 1
            record(field: "droppedFrames", value: self.dropped as AnyObject, timestamp: timestamp)
        }

        func capturedFrame(frameTimestamp: TimeInterval, metricsTimestamp: Date?) {
            self.capturedFrames += 1
            record(field: "capturedFrames", value: self.capturedFrames as AnyObject, timestamp: metricsTimestamp)
            if let metricsTimestamp = metricsTimestamp {
                record(field: "timestamp", value: frameTimestamp as AnyObject, timestamp: metricsTimestamp)
            }
        }

        func pressureStateChanged(level: Int, metricsTimestamp: Date) {
            record(field: "pressureState", value: level as AnyObject, timestamp: metricsTimestamp)
        }
    }
}

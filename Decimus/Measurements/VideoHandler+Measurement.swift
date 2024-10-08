// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension VideoHandler {
    actor VideoHandlerMeasurement: Measurement {
        let id = UUID()
        var name: String = "VideoHandler"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0
        private var decoded: UInt64 = 0

        init(namespace: QuicrNamespace) {
            tags["namespace"] = namespace
        }

        func receivedFrame(timestamp: Date?, idr: Bool) {
            self.frames += 1
            record(field: "receivedFrames",
                   value: self.frames as AnyObject,
                   timestamp: timestamp,
                   tags: ["idr": "\(idr)"])
        }

        func age(age: TimeInterval, timestamp: Date) {
            record(field: "age", value: age as AnyObject, timestamp: timestamp)
        }

        func decodedFrame(timestamp: Date?) {
            self.decoded += 1
            record(field: "decodedFrames", value: self.decoded as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: Int, timestamp: Date?) {
            self.bytes += UInt64(received)
            record(field: "receivedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
        }

        func enqueuedFrame(frameTimestamp: TimeInterval, metricsTimestamp: Date) {
            record(field: "enqueueTimestamp", value: frameTimestamp as AnyObject, timestamp: metricsTimestamp)
        }

        func frameDelay(delay: TimeInterval, metricsTimestamp: Date) {
            record(field: "delay", value: delay, timestamp: metricsTimestamp)
        }
    }
}

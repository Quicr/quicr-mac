// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

extension H264Publication {
    final class VideoPublicationMeasurement: MetricsMeasurement {
        let storage = MeasurementStorage()
        let name = "VideoPublication"
        let tags: [String: String]
        private let bytes = Atomic<UInt64>(0)
        private let pixels = Atomic<UInt64>(0)
        private let publishedFrames = Atomic<UInt64>(0)

        init(namespace: QuicrNamespace) {
            self.tags = ["namespace": namespace]
        }

        func sentFrame(bytes: UInt64, timestamp: TimeInterval, age: TimeInterval?, metricsTimestamp: Date?) {
            let frameVal = publishedFrames.wrappingAdd(1, ordering: .relaxed).newValue
            let byteVal = self.bytes.wrappingAdd(bytes, ordering: .relaxed).newValue
            record(field: "sentBytes", value: byteVal as AnyObject, timestamp: metricsTimestamp)
            record(field: "publishedFrames", value: frameVal as AnyObject, timestamp: metricsTimestamp)
            if let metricsTimestamp = metricsTimestamp {
                record(field: "timestamp", value: timestamp as AnyObject, timestamp: metricsTimestamp)
                assert(age != nil)
                record(field: "publishedAge", value: age as AnyObject, timestamp: metricsTimestamp)
            }
        }

        func sentPixels(sent: UInt64, timestamp: Date?) {
            let val = pixels.wrappingAdd(sent, ordering: .relaxed).newValue
            record(field: "sentPixels", value: val as AnyObject, timestamp: timestamp)
        }

        func age(age: TimeInterval, presentationTimestamp: TimeInterval, metricsTimestamp: Date) {
            let tags = ["timestamp": "\(presentationTimestamp)"]
            record(field: "age", value: age as AnyObject, timestamp: metricsTimestamp, tags: tags)
        }

        func encoded(age: TimeInterval, timestamp: Date) {
            record(field: "encodedAge", value: age as AnyObject, timestamp: timestamp)
        }

        func audioActivity(_ value: UInt8, timestamp: Date) {
            record(field: "audioActivity", value: value as AnyObject, timestamp: timestamp)
        }
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension H264Publication {
    actor VideoPublicationMeasurement: Measurement {
        let id = UUID()
        var name: String = "VideoPublication"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var bytes: UInt64 = 0
        private var pixels: UInt64 = 0
        private var publishedFrames: UInt64 = 0

        init(namespace: QuicrNamespace) {
            tags["namespace"] = namespace
        }

        func sentFrame(bytes: UInt64, timestamp: TimeInterval, age: TimeInterval?, metricsTimestamp: Date?) {
            self.publishedFrames += 1
            self.bytes += bytes
            record(field: "sentBytes", value: self.bytes as AnyObject, timestamp: metricsTimestamp)
            record(field: "publishedFrames", value: self.publishedFrames as AnyObject, timestamp: metricsTimestamp)
            if let metricsTimestamp = metricsTimestamp {
                record(field: "timestamp", value: timestamp as AnyObject, timestamp: metricsTimestamp)
                assert(age != nil)
                record(field: "publishedAge", value: age as AnyObject, timestamp: metricsTimestamp)
            }
        }

        func sentPixels(sent: UInt64, timestamp: Date?) {
            self.pixels += sent
            record(field: "sentPixels", value: self.pixels as AnyObject, timestamp: timestamp)
        }

        func age(age: TimeInterval, presentationTimestamp: TimeInterval, metricsTimestamp: Date) {
            let tags = ["timestamp": "\(presentationTimestamp)"]
            record(field: "age", value: age as AnyObject, timestamp: metricsTimestamp, tags: tags)
        }

        func encoded(age: TimeInterval, timestamp: Date) {
            record(field: "encodedAge", value: age as AnyObject, timestamp: timestamp)
        }
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension OpusPublication {
    actor OpusPublicationMeasurement: Measurement {
        let id = UUID()
        var name: String = "OpusPublication"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0

        init(namespace: QuicrNamespace) {
            tags["namespace"] = namespace
        }

        func publishedBytes(sentBytes: Int, timestamp: Date?) {
            self.frames += 1
            self.bytes += UInt64(sentBytes)
            record(field: "publishedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
            record(field: "publishedFrames", value: self.frames as AnyObject, timestamp: timestamp)
        }

        func encode(_ count: Int, timestamp: Date) {
            record(field: "encode", value: count as AnyObject, timestamp: timestamp)
        }
    }
}

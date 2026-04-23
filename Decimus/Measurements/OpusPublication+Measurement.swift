// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

extension OpusPublication {
    final class OpusPublicationMeasurement: MeasurementBase {
        private let frames = Atomic<UInt64>(0)
        private let bytes = Atomic<UInt64>(0)

        init(namespace: String) {
            super.init(name: "OpusPublication", tags: ["namespace": namespace])
        }

        func publishedBytes(sentBytes: Int, timestamp: Date?) {
            let frameVal = frames.wrappingAdd(1, ordering: .relaxed).newValue
            let byteVal = bytes.wrappingAdd(UInt64(sentBytes), ordering: .relaxed).newValue
            record(field: "publishedBytes", value: byteVal as AnyObject, timestamp: timestamp)
            record(field: "publishedFrames", value: frameVal as AnyObject, timestamp: timestamp)
        }

        func encode(_ count: Int, timestamp: Date) {
            record(field: "encode", value: count as AnyObject, timestamp: timestamp)
        }

        func audioActivity(_ value: UInt8, voiceActive: Bool, timestamp: Date) {
            record(field: "audioActivity", value: value as AnyObject, timestamp: timestamp)
            record(field: "voiceActive", value: (voiceActive ? 1 : 0) as AnyObject, timestamp: timestamp)
        }
    }
}

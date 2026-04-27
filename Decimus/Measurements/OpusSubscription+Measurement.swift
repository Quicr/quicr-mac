// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFAudio
import Synchronization

extension OpusSubscription {
    final class OpusSubscriptionMeasurement: MetricsMeasurement {
        let storage = MeasurementStorage()
        let name = "OpusSubscription"
        let tags: [String: String]
        private let frames = Atomic<UInt64>(0)
        private let bytes = Atomic<UInt64>(0)
        private let missing = Atomic<UInt64>(0)
        private let dropped = Atomic<UInt64>(0)
        private let playoutFullCount = Atomic<UInt64>(0)

        init(namespace: QuicrNamespace) {
            self.tags = ["namespace": namespace]
        }

        func receivedFrames(received: AVAudioFrameCount, timestamp: Date?) {
            let val = frames.wrappingAdd(UInt64(received), ordering: .relaxed).newValue
            record(field: "receivedFrames", value: val as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: UInt, timestamp: Date?) {
            let val = bytes.wrappingAdd(UInt64(received), ordering: .relaxed).newValue
            record(field: "receivedBytes", value: val as AnyObject, timestamp: timestamp)
        }

        func missingSeq(missingCount: UInt64, timestamp: Date?) {
            let val = missing.wrappingAdd(missingCount, ordering: .relaxed).newValue
            record(field: "missingSeqs", value: val as AnyObject, timestamp: timestamp)
        }

        func framesUnderrun(underrun: UInt64, timestamp: Date?) {
            record(field: "framesUnderrun", value: underrun as AnyObject, timestamp: timestamp)
        }

        func concealmentFrames(concealed: UInt64, timestamp: Date?) {
            record(field: "framesConcealed", value: concealed as AnyObject, timestamp: timestamp)
        }

        func callbacks(callbacks: UInt64, timestamp: Date?) {
            record(field: "callbacks", value: callbacks as AnyObject, timestamp: timestamp)
        }

        func removedSilence(removed: UInt64, timestamp: Date?) {
            record(field: "removedSilence", value: removed as AnyObject, timestamp: timestamp)
        }

        func recordLibJitterMetrics(metrics: Metrics, timestamp: Date?) {
            record(field: "concealed", value: metrics.concealed_frames as AnyObject, timestamp: timestamp)
            record(field: "filled", value: metrics.filled_packets as AnyObject, timestamp: timestamp)
            record(field: "skipped", value: metrics.skipped_frames as AnyObject, timestamp: timestamp)
            record(field: "missed", value: metrics.update_missed_frames as AnyObject, timestamp: timestamp)
            record(field: "updated", value: metrics.updated_frames as AnyObject, timestamp: timestamp)
        }

        func droppedFrames(dropped: Int, timestamp: Date?) {
            let val = self.dropped.wrappingAdd(UInt64(dropped), ordering: .relaxed).newValue
            record(field: "dropped", value: val as AnyObject, timestamp: timestamp)
        }

        func depth(depthMs: Int, timestamp: Date) {
            record(field: "currentDepth", value: TimeInterval(depthMs) / 1000.0, timestamp: timestamp)
        }

        func frameDelay(delay: TimeInterval, metricsTimestamp: Date) {
            record(field: "delay", value: delay, timestamp: metricsTimestamp)
        }

        func playoutFull(timestamp: Date?) {
            let val = playoutFullCount.wrappingAdd(1, ordering: .relaxed).newValue
            record(field: "playoutFull", value: val as AnyObject, timestamp: timestamp)
        }
    }
}

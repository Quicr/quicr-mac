// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

extension JitterBuffer {
    final class JitterBufferMeasurement: MeasurementBase {
        private let underruns = Atomic<UInt64>(0)
        private let reads = Atomic<UInt64>(0)
        private let writes = Atomic<UInt64>(0)
        private let flushedCount = Atomic<UInt64>(0)
        private let pausedWaitTime = Mutex<Bool>(false)

        init(namespace: QuicrNamespace) {
            super.init(name: "VideoJitterBuffer", tags: ["namespace": namespace])
        }

        func currentDepth(depth: TimeInterval, target: TimeInterval, adjustment: TimeInterval, timestamp: Date?) {
            guard depth.isFinite,
                  depth.truncatingRemainder(dividingBy: 1) != 0 else {
                return
            }
            record(field: "currentDepth", value: UInt32(depth * 1000) as AnyObject, timestamp: timestamp)
            self.record(field: "targetDepth", value: target, timestamp: timestamp)
            if adjustment > 0 {
                self.record(field: "adjustment", value: adjustment, timestamp: timestamp)
            }
        }

        func underrun(timestamp: Date?) {
            let val = underruns.wrappingAdd(1, ordering: .relaxed).newValue
            record(field: "underruns", value: val as AnyObject, timestamp: timestamp)
        }

        func write(timestamp: Date?) {
            let val = writes.wrappingAdd(1, ordering: .relaxed).newValue
            record(field: "writes", value: val as AnyObject, timestamp: timestamp)
        }

        func flushed(count: UInt, timestamp: Date?) {
            let val = flushedCount.wrappingAdd(UInt64(count), ordering: .relaxed).newValue
            record(field: "flushed", value: val as AnyObject, timestamp: timestamp)
        }

        func waitTime(value: TimeInterval, timestamp: Date?) {
            let paused = pausedWaitTime.withLock { paused in
                if paused && value < 0 {
                    return true
                }
                paused = value < 0
                return false
            }
            guard !paused else { return }
            record(field: "waitTime", value: value as AnyObject, timestamp: timestamp)
        }

        func read(timestamp: Date?) {
            let val = reads.wrappingAdd(1, ordering: .relaxed).newValue
            record(field: "reads", value: val as AnyObject, timestamp: timestamp)
        }
    }
}

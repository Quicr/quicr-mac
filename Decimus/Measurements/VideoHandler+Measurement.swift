// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

extension VideoHandler {
    final class VideoHandlerMeasurement: MetricsMeasurement {
        let storage = MeasurementStorage()
        let name = "VideoHandler"
        let tags: [String: String]
        private let frames = Atomic<UInt64>(0)
        private let bytes = Atomic<UInt64>(0)
        private let decoded = Atomic<UInt64>(0)

        init(namespace: QuicrNamespace) {
            self.tags = ["namespace": namespace]
        }

        func timestamp(timestamp: TimeInterval, when: Date, cached: Bool) {
            let tags = ["cached": "\(cached)"]
            self.record(field: "timestamp", value: timestamp, timestamp: when, tags: tags)
        }

        func receivedFrame(timestamp: Date?, idr: Bool, cached: Bool) {
            let val = frames.wrappingAdd(1, ordering: .relaxed).newValue
            let tags: [String: String]?
            if timestamp != nil {
                tags = ["idr": "\(idr)", "cached": "\(cached)"]
            } else {
                tags = nil
            }
            record(field: "receivedFrames",
                   value: val as AnyObject,
                   timestamp: timestamp,
                   tags: tags)
        }

        func age(age: TimeInterval, timestamp: Date, cached: Bool) {
            let tags = ["cached": "\(cached)"]
            record(field: "age", value: age as AnyObject, timestamp: timestamp, tags: tags)
        }

        func writeDecoder(age: TimeInterval, timestamp: Date) {
            self.record(field: "ageDecode", value: age, timestamp: timestamp)
        }

        func decodedAge(age: TimeInterval, timestamp: Date) {
            self.record(field: "ageDecoded", value: age, timestamp: timestamp)
        }

        func decodedFrame(timestamp: Date?) {
            let val = decoded.wrappingAdd(1, ordering: .relaxed).newValue
            record(field: "decodedFrames", value: val as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: Int, timestamp: Date?, cached: Bool) {
            let val = bytes.wrappingAdd(UInt64(received), ordering: .relaxed).newValue
            let tags: [String: String]?
            if timestamp != nil {
                tags = ["cached": "\(cached)"]
            } else {
                tags = nil
            }
            record(field: "receivedBytes", value: val as AnyObject, timestamp: timestamp, tags: tags)
        }

        func enqueuedFrame(frameTimestamp: TimeInterval, metricsTimestamp: Date) {
            record(field: "enqueueTimestamp", value: frameTimestamp as AnyObject, timestamp: metricsTimestamp)
        }

        func frameDelay(delay: TimeInterval, metricsTimestamp: Date) {
            record(field: "delay", value: delay, timestamp: metricsTimestamp)
        }

        func dequeueTiming(_ timing: VideoJitterDequeueTiming, timestamp: Date) {
            let tags = ["resumed_from_empty": "\(timing.resumedFromEmpty)"]
            self.record(field: "dequeueScheduledWait",
                        value: timing.scheduledWaitSeconds,
                        timestamp: timestamp,
                        tags: tags)
            if let deadlineLateness = timing.deadlineLatenessSeconds {
                self.record(field: "dequeueDeadlineLateness",
                            value: deadlineLateness,
                            timestamp: timestamp,
                            tags: tags)
            }
            if let bufferDepth = timing.bufferDepthSeconds {
                self.record(field: "dequeueBufferDepth",
                            value: bufferDepth,
                            timestamp: timestamp,
                            tags: tags)
            }
        }

        func displayEnqueueTiming(_ timing: VideoDisplayEnqueueTiming, timestamp: Date) {
            let tags = [
                "display_immediately": "\(timing.displayImmediately)",
                "ready_for_more_media_data": "\(timing.readyForMoreMediaData)"
            ]
            self.record(field: "displayFrameAge",
                        value: timing.frameAgeSeconds,
                        timestamp: timestamp,
                        tags: tags)
            self.record(field: "displayMainActorQueueDelay",
                        value: timing.mainActorQueueDelaySeconds,
                        timestamp: timestamp,
                        tags: tags)
            if let presentationLead = timing.scheduledPresentationLeadSeconds {
                self.record(field: "displayScheduledPresentationLead",
                            value: presentationLead,
                            timestamp: timestamp,
                            tags: tags)
            }
        }

        func moqTraversalTime(time: TimeInterval, metricsTimestamp: Date) {
            self.record(field: "traversalTime", value: time, timestamp: metricsTimestamp)
        }
    }
}

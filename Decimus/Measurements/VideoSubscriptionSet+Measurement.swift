// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia

extension VideoSubscriptionSet {
    struct SimulreceiveChoiceReport {
        let item: SimulreceiveItem
        let selected: Bool
        let reason: String
        let displayed: Bool
    }

    final class VideoSubscriptionMeasurement: MetricsMeasurement {
        let storage = MeasurementStorage()
        let name = "VideoSubscription"
        let tags: [String: String]

        init(source: SourceIDType) {
            self.tags = ["sourceId": source]
        }

        func reportSimulreceiveChoice(choices: [SimulreceiveChoiceReport], timestamp: Date) throws {
            var offset: TimeInterval = 0
            for choice in choices {
                let height = choice.item.image.image.formatDescription!.dimensions.height
                let tags: [String: String] = [
                    "namespace": "\(choice.item.fullTrackName)",
                    "selected": String(choice.selected),
                    "timestamp": String(choice.item.image.image.presentationTimeStamp.seconds),
                    "reason": choice.reason,
                    "displayed": String(choice.displayed)
                ]
                record(field: "selection", value: height as AnyObject, timestamp: timestamp + offset, tags: tags)
                offset += (1 / 1_000_000)
            }
        }

        func reportVariance(variance: TimeInterval, when: Date) {
            record(field: "variance", value: variance as AnyObject, timestamp: when)
        }

        func age(_ age: TimeInterval, timestamp: Date) {
            self.record(field: "age", value: age, timestamp: timestamp)
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
    }
}

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

    class VideoSubscriptionMeasurement: Measurement {
        init(source: SourceIDType) {
            super.init(name: "VideoSubscription", tags: ["sourceId": source])
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
    }
}

import CoreMedia

extension VideoSubscription {
    actor _Measurement: Measurement {
        let id = UUID()
        var name: String = "VideoSubscription"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        init(source: SourceIDType) {
            tags["sourceId"] = source
        }

        struct SimulreceiveChoiceReport {
            let item: SimulreceiveItem
            let selected: Bool
            let reason: String
            let displayed: Bool
        }

        func reportSimulreceiveChoice(choices: [SimulreceiveChoiceReport], timestamp: Date) {
            var offset: TimeInterval = 0
            for choice in choices {
                let height = choice.item.image.image.formatDescription!.dimensions.height
                let tags: [String: String] = [
                    "namespace": choice.item.namespace,
                    "selected": String(choice.selected),
                    "timestamp": String(choice.item.image.image.presentationTimeStamp.seconds),
                    "reason": choice.reason,
                    "displayed": String(choice.displayed)
                ]
                record(field: "selection", value: height as AnyObject, timestamp: timestamp + offset, tags: tags)
                offset += (1 / 1_000_000)
            }
        }

        func reportTimestamp(namespace: QuicrNamespace, timestamp: TimeInterval, at: Date) {
            let tags: [String: String] = ["namespace": namespace]
            record(field: "timestamp", value: timestamp as AnyObject, timestamp: at, tags: tags)
        }

        func reportVariance(variance: TimeInterval, at: Date) {
            record(field: "variance", value: variance as AnyObject, timestamp: at)
        }
    }
}

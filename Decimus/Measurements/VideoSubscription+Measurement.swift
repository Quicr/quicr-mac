import CoreMedia

extension VideoSubscription {
    struct SimulreceiveChoiceReport {
        let item: SimulreceiveItem
        let selected: Bool
        let reason: String
        let displayed: Bool
    }

    actor VideoSubscriptionMeasurement: QuicrMeasurementHandler {
        let id = UUID()
        let measurement: QuicrMeasurement

        init(source: SourceIDType) {
            measurement = .init("VideoSubscription")
            measurement.tag(attr: .init(name:"sourceId", type: "string", value: source))
        }

        func reportSimulreceiveChoice(choices: [SimulreceiveChoiceReport], timestamp: Date) {
            var offset: TimeInterval = 0
            for choice in choices {
                let height = choice.item.image.image.formatDescription!.dimensions.height

                measurement.tag(attr: .init(name: "namespace", type: "string", value: choice.item.namespace))
                measurement.tag(attr: .init(name: "selected", type: "string", value: String(choice.selected)))
                measurement.tag(attr: .init(name: "timestamp", type: "uint64", value: String(choice.item.image.image.presentationTimeStamp.seconds)))
                measurement.tag(attr: .init(name: "reason", type: "string", value: choice.reason))
                measurement.tag(attr: .init(name: "displayed", type: "string", value: String(choice.displayed)))

                measurement.record(field: "selection", value: height as AnyObject, timestamp: timestamp + offset)
                offset += (1 / 1_000_000)
            }
        }

        func reportTimestamp(namespace: QuicrNamespace, timestamp: TimeInterval, at: Date) {
            measurement.tag(attr: .init(name: "namespace", type: "string", value: namespace))
            measurement.record(field: "timestamp", value: timestamp as AnyObject, timestamp: at)
        }

        func reportVariance(variance: TimeInterval, at: Date) {
            measurement.record(field: "variance", value: variance as AnyObject, timestamp: at)
        }
    }
}

// import InfluxDBSwift
import Foundation

actor InfluxMetricsSubmitter: MetricsSubmitter {

    // private let client: InfluxDBClient
    private var measurements: [Measurement] = []
    private var submissionTask: Task<(), Never>?

    init(config: InfluxConfig) {
        // Create the influx API instance.
//        client = .init(url: config.url,
//                       token: config.token,
//                       options: .init(bucket: config.bucket,
//                                      org: config.org))
    }

    func startSubmitting(interval: Int) {
        submissionTask = .init(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.writeAll()
                try? await Task.sleep(until: .now + .seconds(5), tolerance: .seconds(1), clock: .continuous)
            }
        }
    }

    func register(measurement: Measurement) {
        measurements.append(measurement)
    }

    private func writeAll() async {
//        var points: [InfluxDBClient.Point] = []
//        for measurement in measurements {
//            for timestampedDict in await measurement.fields {
//                let point: InfluxDBClient.Point = .init(await measurement.name)
//                for tag in await measurement.tags {
//                    point.addTag(key: tag.key, value: tag.value)
//                }
//                if let realTime = timestampedDict.key {
//                    point.time(time: .date(realTime))
//                }
//                for fields in timestampedDict.value {
//                    point.addField(key: fields.key, value: Self.getFieldValue(value: fields.value))
//                    points.append(point)
//                }
//            }
//        }
//
//        guard !points.isEmpty else { return }
//
//        do {
//            try await client.makeWriteAPI().write(points: points, responseQueue: .global(qos: .utility))
//        } catch {
//            print("Failed to write: \(error)")
//        }
    }

//    private static func getFieldValue(value: AnyObject) -> InfluxDBClient.Point.FieldValue? {
//        switch value {
//        case is Int16, is Int32, is Int64:
//            return .int((value as? Int)!)
//        case is UInt8, is UInt16, is UInt32, is UInt64:
//            return .uint((value as? UInt)!)
//        case is Float:
//            return .double(Double((value as? Float)!))
//        case is Double:
//            return .double((value as? Double)!)
//        case is String:
//            return .string((value as? String)!)
//        case is Bool:
//            return .boolean((value as? Bool)!)
//        default:
//            return nil
//        }
//    }

    deinit {
        submissionTask?.cancel()
        // client.close()
    }
}

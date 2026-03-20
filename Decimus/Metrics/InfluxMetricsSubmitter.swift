// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import InfluxDBSwift
import Foundation
import Synchronization

final class InfluxMetricsSubmitter: @unchecked Sendable, MetricsSubmitter {
    private class WeakMeasurement {
        weak var measurement: (any Measurement)?
        let id: UUID
        init (_ measurement: any Measurement) {
            self.measurement = measurement
            self.id = measurement.id
        }
    }

    private let logger = DecimusLogger(InfluxMetricsSubmitter.self)

    private let client: InfluxDBClient
    private let measurements = Mutex<[UUID: WeakMeasurement]>([:])
    private let tags: [String: String]

    init(token: String, config: InfluxConfig, tags: [String: String]) {
        client = .init(url: config.url,
                       token: token,
                       options: .init(bucket: config.bucket,
                                      org: config.org,
                                      enableGzip: true))
        self.tags = tags
    }

    func register(measurement: Measurement) {
        measurements.withLock { dict in
            let updated = dict.updateValue(.init(measurement), forKey: measurement.id)
            assert(updated == nil)
            guard updated == nil else {
                self.logger.error("Shouldn't call register for existing measurement: \(measurement)")
                return
            }
        }
    }

    func submit() async {
        // Snapshot measurements under lock, then release.
        let snapshot: [UUID: WeakMeasurement] = measurements.withLock { $0 }

        var points: [InfluxDBClient.Point] = []
        var toRemove: [UUID] = []
        for pair in snapshot {
            let weakMeasurement = pair.value
            guard let measurement = weakMeasurement.measurement else {
                self.logger.warning("Removing dead measurement")
                toRemove.append(weakMeasurement.id)
                continue
            }
            let fields = measurement.drain()
            let name = measurement.name
            let mTags = measurement.tags
            for timestampedDict in fields {
                let point: InfluxDBClient.Point = .init(name)
                for tag in mTags {
                    point.addTag(key: tag.key, value: tag.value)
                }
                for tag in self.tags {
                    point.addTag(key: tag.key, value: tag.value)
                }
                if let realTime = timestampedDict.key {
                    point.time(time: .date(realTime))
                }
                for appPoint in timestampedDict.value {
                    if let tags = appPoint.tags {
                        for tag in tags {
                            point.addTag(key: tag.key, value: tag.value)
                        }
                    }
                    point.addField(key: appPoint.fieldName, value: Self.getFieldValue(value: appPoint.value))
                    points.append(point)
                }
            }
        }

        // Clean up dead weak references.
        if !toRemove.isEmpty {
            measurements.withLock { dict in
                for id in toRemove {
                    dict.removeValue(forKey: id)
                }
            }
        }

        guard !points.isEmpty else { return }

        do {
            try await client.makeWriteAPI().write(points: points, responseQueue: .global(qos: .utility))
        } catch {
            self.logger.warning("Failed to write metrics: \(error)")
        }
    }

    private static func getFieldValue(value: AnyObject) -> InfluxDBClient.Point.FieldValue? {
        switch value {
        case is Int16, is Int32, is Int64:
            return .int((value as? Int)!)
        case is UInt8, is UInt16, is UInt32, is UInt64:
            return .uint((value as? UInt)!)
        case is Float:
            return .double(Double((value as? Float)!))
        case is Double:
            return .double((value as? Double)!)
        case is String:
            return .string((value as? String)!)
        case is Bool:
            return .boolean((value as? Bool)!)
        default:
            return nil
        }
    }

    deinit {
        client.close()
    }
}

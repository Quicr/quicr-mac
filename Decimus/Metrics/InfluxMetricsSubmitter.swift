// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import InfluxDBSwift
import Foundation
import Synchronization

final class InfluxMetricsSubmitter: @unchecked Sendable, MetricsSubmitter {
    private struct FieldGroup {
        let timestamp: Date?
        let tags: [String: String]
        var fields: [Point]
    }

    private class WeakMeasurement {
        weak var measurement: (any MetricsMeasurement)?
        let id: UUID
        init (_ measurement: any MetricsMeasurement) {
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

    func register(measurement: MetricsMeasurement) {
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
        await self.write(points: self.drainPoints())
    }

    func submitInBackground() {
        let points = self.drainPoints()
        guard !points.isEmpty else { return }

        let flushId = UUID()
        let start = ContinuousClock.now
        self.logger.debug("Background metrics flush \(flushId) started with \(points.count) points")
        Task(priority: .utility) {
            await self.write(points: points)
            let elapsed = start.duration(to: .now)
            self.logger.debug("Background metrics flush \(flushId) finished after \(elapsed)")
        }
    }

    private func drainPoints() -> [InfluxDBClient.Point] {
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
            points.append(contentsOf: Self.makePoints(fields: fields,
                                                      name: name,
                                                      measurementTags: mTags,
                                                      baseTags: self.tags))
        }

        // Clean up dead weak references.
        if !toRemove.isEmpty {
            measurements.withLock { dict in
                for id in toRemove {
                    dict.removeValue(forKey: id)
                }
            }
        }

        return points
    }

    static func makePoints(fields: Fields,
                           name: String,
                           measurementTags: [String: String],
                           baseTags: [String: String]) -> [InfluxDBClient.Point] {
        Self.groupFields(fields).map { group in
            let point = InfluxDBClient.Point(name)
            for tag in measurementTags {
                point.addTag(key: tag.key, value: tag.value)
            }
            for tag in baseTags {
                point.addTag(key: tag.key, value: tag.value)
            }
            for tag in group.tags {
                point.addTag(key: tag.key, value: tag.value)
            }
            if let timestamp = group.timestamp {
                point.time(time: .date(timestamp))
            }
            for field in group.fields {
                point.addField(key: field.fieldName, value: Self.getFieldValue(value: field.value))
            }
            return point
        }
    }

    private static func groupFields(_ fields: Fields) -> [FieldGroup] {
        fields.flatMap { timestamp, timestampedFields in
            timestampedFields.reduce(into: [FieldGroup]()) { groups, field in
                let tags = field.tags ?? [:]
                if let index = groups.firstIndex(where: { $0.tags == tags }) {
                    groups[index].fields.append(field)
                } else {
                    groups.append(.init(timestamp: timestamp, tags: tags, fields: [field]))
                }
            }
        }
    }

    private func write(points: [InfluxDBClient.Point]) async {
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

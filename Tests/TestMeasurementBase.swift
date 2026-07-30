// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import Testing

private final class TestMeasurement: MetricsMeasurement {
    let storage = MeasurementStorage()
    let name = "Test"
    let tags: [String: String] = ["key": "value"]
}

@Suite
struct TestMeasurementBase {
    @Test func recordAndDrain() {
        let measurement = TestMeasurement()
        let now = Date.now

        measurement.record(field: "counter", value: 42 as AnyObject, timestamp: now)
        measurement.record(field: "gauge", value: 3.14 as AnyObject, timestamp: now)

        let fields = measurement.drain()
        #expect(fields.count == 1)
        #expect(fields[now]?.count == 2)
        #expect(fields[now]?[0].fieldName == "counter")
        #expect(fields[now]?[1].fieldName == "gauge")

        // Drain again should be empty.
        let empty = measurement.drain()
        #expect(empty.isEmpty)
    }

    @Test func drainIsAtomic() {
        let measurement = TestMeasurement()

        // Record, drain, record more — second drain should only have new data.
        measurement.record(field: "a", value: 1 as AnyObject, timestamp: nil)
        let first = measurement.drain()
        #expect(first.count == 1)

        measurement.record(field: "b", value: 2 as AnyObject, timestamp: nil)
        let second = measurement.drain()
        #expect(second.count == 1)
        #expect(second[nil]?[0].fieldName == "b")
    }

    @Test func properties() {
        let measurement = TestMeasurement()
        #expect(measurement.name == "Test")
        #expect(measurement.tags == ["key": "value"])
    }

    @Test func concurrentRecordAndDrain() async {
        let measurement = TestMeasurement()
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<iterations {
                group.addTask {
                    measurement.record(field: "field\(index)", value: index as AnyObject, timestamp: nil)
                }
            }
            for _ in 0..<10 {
                group.addTask {
                    _ = measurement.drain()
                }
            }
        }

        // Final drain should get whatever remains — no crash = success.
        _ = measurement.drain()
    }

    @Test func backgroundSubmitDrainsSynchronously() {
        let measurement = TestMeasurement()
        var config = InfluxConfig()
        config.url = "http://127.0.0.1:1"
        config.bucket = "test"
        config.org = "test"
        let submitter = InfluxMetricsSubmitter(token: "", config: config, tags: [:])
        submitter.register(measurement: measurement)
        measurement.record(field: "counter", value: Int64(42) as AnyObject, timestamp: nil)

        submitter.submitInBackground()

        #expect(measurement.drain().isEmpty)
    }

    @Test func fieldsWithMatchingTimestampAndTagsProduceOneInfluxPoint() throws {
        let timestamp = Date(timeIntervalSince1970: 1)
        let fields: Fields = [
            timestamp: [
                .init(fieldName: "first", value: Int64(1) as AnyObject, tags: ["source": "camera"]),
                .init(fieldName: "second", value: Int64(2) as AnyObject, tags: ["source": "camera"])
            ]
        ]

        let points = InfluxMetricsSubmitter.makePoints(fields: fields,
                                                       name: "Test",
                                                       measurementTags: ["measurement": "tag"],
                                                       baseTags: ["base": "tag"])

        #expect(points.count == 1)
        let protocolLine = try points.first?.toLineProtocol()
        let line = try #require(protocolLine)
        #expect(line == "Test,base=tag,measurement=tag,source=camera first=1i,second=2i 1000000000")
    }

    @Test func fieldsWithDifferentTagsProduceSeparateInfluxPoints() throws {
        let timestamp = Date(timeIntervalSince1970: 1)
        let fields: Fields = [
            timestamp: [
                .init(fieldName: "age", value: Int64(1) as AnyObject, tags: ["source": "camera"]),
                .init(fieldName: "age", value: Int64(2) as AnyObject, tags: ["source": "screen"])
            ]
        ]

        let points = InfluxMetricsSubmitter.makePoints(fields: fields,
                                                       name: "Test",
                                                       measurementTags: [:],
                                                       baseTags: [:])
        let lines = try points.map { point in
            let protocolLine = try point.toLineProtocol()
            return try #require(protocolLine)
        }

        #expect(points.count == 2)
        #expect(Set(lines) == [
            "Test,source=camera age=1i 1000000000",
            "Test,source=screen age=2i 1000000000"
        ])
    }
}

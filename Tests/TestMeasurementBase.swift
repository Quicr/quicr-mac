// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import Testing

private final class TestMeasurement: MeasurementBase {
    init() {
        super.init(name: "Test", tags: ["key": "value"])
    }
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
}

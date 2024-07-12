struct Point {
    let fieldName: String
    let value: AnyObject
    let tags: [String: String]?
}

typealias Fields = [Date?: [Point]]

protocol Measurement: AnyObject, Actor {
    nonisolated var id: UUID { get }
    var name: String { get }
    var fields: Fields { get set }
    var tags: [String: String] { get }
    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]?)
    func toQuicrMeasurements() throws -> [QuicrMeasurement]
}

extension Measurement {
    func record(field: String, value: AnyObject, timestamp: Date?, tags: [String: String]? = nil) {
        if fields[timestamp] == nil {
            fields[timestamp] = []
        }
        fields[timestamp]!.append(.init(fieldName: field, value: value, tags: tags))
    }

    func record(field: String, value: Double, timestamp: Date?, tags: [String: String]? = nil) {
        let floatValue: TimeInterval
        if value == 0 || Int(exactly: value) != nil {
            floatValue = value + .ulpOfOne
        } else {
            floatValue = value
        }
        record(field: field, value: floatValue as AnyObject, timestamp: timestamp, tags: tags)
    }

    func clear() {
        fields.removeAll(keepingCapacity: true)
    }

    func toQuicrMeasurements() -> [QuicrMeasurement] {
        var measurements = [QuicrMeasurement]()
        for (timestamp, points) in self.fields {
            var measurement = QuicrMeasurement(self.name)

            for (key, value) in tags {
                measurement.tag(key, value: value)
            }

            for point in points {
                measurement.record(field: point.fieldName, value: point.value)
            }
            measurement.setTime(timestamp)

            measurements.append(measurement)
        }

        return measurements
    }
}

struct Attribute: Encodable {
    var name: String
    var type: String?
    var value: String

    init(name: String, type: String? = nil, value: String) {
        self.name = name
        self.type = type
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case name  = "an"
        case type  = "at"
        case value = "av"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        if type != nil {
            try container.encode(type, forKey: .type)
        }
        try container.encode(value, forKey: .value)
    }
}

struct Metric: Encodable {
    var name: String
    var type: String
    var value: Any?

    init(name: String, type: String, value: Any?) {
        self.name = name
        self.type = type
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case name  = "mn"
        case type  = "mt"
        case value = "mv"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)

        if let value = self.value as? String {
          try container.encode(value, forKey: .value)
        } else if let value = self.value as? UInt {
          try container.encode(value, forKey: .value)
        } else if let value = self.value as? Double {
          try container.encode(value, forKey: .value)
        }
    }
}

protocol QuicrMeasurementHandler {
    nonisolated var id: UUID { get }
    var measurement: QuicrMeasurement { get }
}

class QuicrMeasurement: Encodable {
    let name: String
    var timestamp: Date = Date.now
    var attributes: [String: Attribute] = [:]
    var metrics: [String: Metric] = [:]

    enum CodingKeys: String, CodingKey {
        case timestamp     = "ts"
        case timeprecision = "tp"
        case attributes    = "attrs"
        case metrics
    }

    init(_ name: String) {
        self.name = name
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(Int64(timestamp.timeIntervalSince1970 * 1_000_000), forKey: .timestamp)
        try container.encode("u", forKey: .timeprecision)

        if !attributes.isEmpty {
            var attrs = attributes.reduce(into: [Attribute]()) { $0.append($1.value) }
            attrs.append(Attribute(name: "an", type: "imn", value: name))
            try container.encodeIfPresent(attrs, forKey: .attributes)
        }

        let metrics = self.metrics.reduce(into: [Metric]()) { $0.append($1.value) }
        try container.encodeIfPresent(metrics, forKey: .metrics)
    }

    func tag(_ name: String, type: String? = nil, value: String) {
        attributes[name] = .init(name: name, type: type, value: value)
    }

    func setTime(_ timestamp: Date?) {
        if let tstamp = timestamp { self.timestamp = tstamp }
    }

    func record(field: String, value: AnyObject) {
        var type: String
        switch value {
        case is UInt64:
            type = "uint64"
        case is Float:
            type = "float32"
        case is Double:
            type = "float64"
        default:
            type = "uint64"
        }

        metrics[field] = .init(name: field, type: type, value: value)
    }
}

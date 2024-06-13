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
}

struct Attribute: Codable {
    let name: String
    let type: String
    let value: String
}

struct Metric: Codable {
    let name: String
    let type: String
    var value: Any?

    enum CodingKeys: String, CodingKey {
        case mn
        case mt
        case mv
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .mn)
        type = try values.decode(String.self, forKey: .mt)
        value = try values.decode(UInt64.self, forKey: .mv)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .mn)
        try container.encode(type, forKey: .mt)

        if let value = self.value as? String {
          try container.encode(value, forKey: .mv)
        } else if let value = self.value as? UInt {
          try container.encode(value, forKey: .mv)
        } else if let value = self.value as? Double {
          try container.encode(value, forKey: .mv)
        }
    }
}

struct QuicrMeasurement: Codable {
    var name: String
    var timestamp: Date
    var attributes: [Attribute]
    var metrics: [Metric]

    enum CodingKeys: String, CodingKey {
        case ts
        case tp
        case attrs
        case metrics
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        var attrs = try values.decode([Attribute].self, forKey: .attrs)
        name = attrs.first { $0.type == "imn" }!.name
        attrs.removeAll{ $0.type == "imn" }

        attributes = attrs
        metrics = try values.decode([Metric].self, forKey: .metrics)
        timestamp = Date(timeIntervalSince1970: TimeInterval(try values.decode(Int.self, forKey: .ts)))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        var attrs = attributes
        attrs.append(Attribute(name: "an", type: "imn", value: name))

        try container.encode(Int(timestamp.timeIntervalSince1970), forKey: .ts)
        try container.encode("u", forKey: .tp)
        try container.encode(attrs, forKey: .attrs)
        try container.encode(metrics, forKey: .metrics)
    }
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
}

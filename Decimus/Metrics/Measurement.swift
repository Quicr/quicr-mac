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

struct Attribute: Codable {
    var name: String
    var type: String
    var value: String

    init(name: String, type: String, value: String) {
        self.name = name
        self.type = type
        self.value = value
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: any Decoder) throws {
        name = ""
        type = ""
        value = ""
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)

        try container.encode(value, forKey: AnyKey(stringValue: name)!)
        try container.encode(type, forKey: AnyKey(stringValue: "at")!)
    }
}

struct Metric: Codable {
    var name: String
    var type: String
    var value: Any?

    init(name: String, type: String, value: Any?) {
        self.name = name
        self.type = type
        self.value = value
    }

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


enum QuicrMeasurementCodingKeys: String, CodingKey {
    case ts
    case tp
    case attrs
    case metrics
}

protocol QuicrMeasurementHandler {
    var measurement: QuicrMeasurement { get }
}

class QuicrMeasurement: Codable {
    let name: String
    var timestamp: Date = Date.now
    var attributes: [Attribute] = []
    var metrics: [Metric] = []

    init(_ name: String) {
        self.name = name
    }

    required convenience init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: QuicrMeasurementCodingKeys.self)

        var attrs = try values.decode([Attribute].self, forKey: .attrs)
        self.init(attrs.first { $0.type == "imn" }!.name)
        attrs.removeAll { $0.type == "imn" }

        self.attributes = attrs
        self.metrics = try values.decode([Metric].self, forKey: .metrics)
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(try values.decode(Int.self, forKey: .ts)))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: QuicrMeasurementCodingKeys.self)

        var attrs = attributes
        attrs.append(Attribute(name: "an", type: "imn", value: name))

        try container.encode(Int(timestamp.timeIntervalSince1970), forKey: .ts)
        try container.encode("u", forKey: .tp)
        try container.encode(attrs, forKey: .attrs)
        try container.encode(metrics, forKey: .metrics)
    }

    func tag(attr: Attribute) {
        if var foundAttr = attributes.first(where: { return $0.name == attr.name }) {
            foundAttr.name = attr.name
            foundAttr.type = attr.type
            foundAttr.value = attr.value
        } else {
            attributes.append(attr)
        }
    }

    func record(field: String, value: AnyObject, timestamp: Date?) {
        metrics.append(.init(name: field, type: "\(type(of: value))", value: value))
        if let ts = timestamp { self.timestamp = ts }
    }
}

extension QuicrMeasurement {
}

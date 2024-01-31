import Foundation

protocol Measurement: Actor {
    var name: String { get }
    var fields: [Date?: [String: AnyObject]] { get set }
    var tags: [String: String] { get }
    func record(field: String, value: AnyObject, timestamp: Date?)
}

extension Measurement {
    func record(field: String, value: AnyObject, timestamp: Date?) {
        if fields[timestamp] == nil {
            fields[timestamp] = [:]
        }
        fields[timestamp]![field] = value
    }

    func clear() {
        fields.removeAll(keepingCapacity: true)
    }
}

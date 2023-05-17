import Foundation

protocol Measurement: Actor {
    var name: String { get }
    var fields: [Date?: [String: AnyObject]] { get }
    var tags: [String] { get }
    func record(field: String, value: AnyObject, timestamp: Date?)
}

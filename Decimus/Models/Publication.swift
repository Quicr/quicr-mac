import Foundation
import AVFoundation

actor PublicationMeasurement: Measurement {
    let id = UUID()
    var name: String = "Publication"
    var fields: Fields = [:]
    var tags: [String: String] = [:]

    private var bytes: UInt64 = 0

    init(namespace: QuicrNamespace) {
        tags["namespace"] = namespace
    }

    func sentBytes(sent: UInt64, timestamp: Date?) {
        self.bytes += sent
        record(field: "sentBytes", value: self.bytes as AnyObject, timestamp: timestamp)
    }
}

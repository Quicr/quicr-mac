import Foundation

struct MetricsConfig: Codable {
    var submit: Bool  = false
    var granular: Bool = false
    var realtime: Bool = true
    var intervalSecs: Int = 5
    var namespace: String = "0xA11CEB0B000000000000000000000000/96"
    var priority: UInt8 = 31
    var ttl: UInt16 = 50000
}

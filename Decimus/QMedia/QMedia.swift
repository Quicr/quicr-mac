import Foundation
import AVFoundation

typealias SourceIDType = String
typealias StreamIDType = UInt64

/// Swift Interface for using QMedia stack.
class MediaClient {
    /// Protocol type mappings
    enum ProtocolType: UInt8, CaseIterable, Codable, Identifiable {
        case UDP = 0
        case QUIC = 1
        var id: UInt8 { rawValue }
    }
}

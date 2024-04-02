import Foundation
import AVFoundation

// swiftlint:disable identifier_name
enum PublicationError: Int32 {
    case None = 0
    case NoSource
}
// swiftlint:enable identifier_name

// TODO: This protocol is redundent.
protocol Publication: QPublicationDelegateObjC {
    var namespace: QuicrNamespace {get}
    var publishObjectDelegate: QPublishObjectDelegateObjC? {get}

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!, transportMode: UnsafeMutablePointer<TransportMode>!) -> Int32
    func update(_ sourceId: String!, qualityProfile: String!) -> Int32
    func publish(_ flag: Bool)
}

protocol AVCaptureDevicePublication: Publication {
    var device: AVCaptureDevice {get}
}

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

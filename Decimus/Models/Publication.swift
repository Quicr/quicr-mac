import Foundation
import AVFoundation

// swiftlint:disable identifier_name
enum PublicationError: Int32 {
    case None = 0
    case NoSource
}
// swiftlint:enable identifier_name

protocol Publication: QPublicationDelegateObjC {
    var namespace: QuicrNamespace {get}
    var publishObjectDelegate: QPublishObjectDelegateObjC? {get}

    func prepare(_ qualityProfile: String!, reliable: UnsafeMutablePointer<Bool>!) -> Int32
    func update(_ qualityProfile: String!) -> Int32
    func publish(_ flag: Bool)
}

protocol AVCaptureDevicePublication: Publication {
    var device: AVCaptureDevice {get}
}

actor PublicationMeasurement: Measurement {
    var name: String = "Publication"
    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    private var bytes: UInt64 = 0

    init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
        tags["namespace"] = namespace
        Task {
            await submitter.register(measurement: self)
        }
    }

    func sentBytes(sent: UInt64, timestamp: Date?) {
        self.bytes += sent
        record(field: "sentBytes", value: self.bytes as AnyObject, timestamp: timestamp)
    }
}

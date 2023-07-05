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
    var device: AVCaptureDevice? {get}

    func prepare(_ sourceID: SourceIDType!, qualityProfile: String!) -> Int32
    func update(_ sourceId: String!, qualityProfile: String!) -> Int32
    func publish(_ flag: Bool)

    func log(_ message: String)
}

extension Publication {
    func log(_ message: String) {
        print("[\(String(describing: type(of: self)))] (\(namespace)) \(message)")
    }
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

actor VideoMeasurement: Measurement {
    var name: String = "VideoPublication"
    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    private var pixels: UInt64 = 0

    init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
        tags["namespace"] = namespace
        Task {
            await submitter.register(measurement: self)
        }
    }

    func sentPixels(sent: UInt64, timestamp: Date?) {
        self.pixels += sent
        record(field: "sentPixels", value: self.pixels as AnyObject, timestamp: timestamp)
    }
}

import Foundation
import AVFoundation

enum OrientationSeiField {
    case tag
    case payloadLength
    case orientation
    case mirror
}

enum TimestampSeiField {
    case type
    case size
    case id
    case timeValue
    case timeScale
    case sequence
    case fps
}

protocol ApplicationSeiData {
    var orientationSei: [UInt8] { get }
    func getOrientationOffset(_ field: OrientationSeiField) -> Int
    
    var timestampSei: [UInt8] { get }
    func getTimestampOffset(_ field: TimestampSeiField) -> Int
}

enum SeiParseError: Error {
    case mismatch
    case parseFailure(String)
}

struct OrientationSei {
    let orientation: DecimusVideoRotation
    let verticalMirror: Bool
    
    init(orientation: DecimusVideoRotation, verticalMirror: Bool) {
        self.orientation = orientation
        self.verticalMirror = verticalMirror
    }
    
    init(encoded: Data, data: ApplicationSeiData) throws {
        let payloadLengthIndex = data.getOrientationOffset(.payloadLength)
        guard encoded.count == data.orientationSei.count,
              encoded[payloadLengthIndex] == data.orientationSei[payloadLengthIndex] else {
            throw SeiParseError.mismatch
        }

        var extractedOrientation: UInt8?
        var extractedVerticalMirror: UInt8?
        encoded.withUnsafeBytes {
            extractedOrientation = $0.loadUnaligned(fromByteOffset: data.getOrientationOffset(.orientation), as: UInt8.self)
            extractedVerticalMirror = $0.loadUnaligned(fromByteOffset: data.getOrientationOffset(.mirror), as: UInt8.self)
        }

        guard let extractedOrientation = extractedOrientation,
              let orientation = DecimusVideoRotation(rawValue: extractedOrientation) else {
            throw SeiParseError.parseFailure("Orientation")
        }
        self.orientation = orientation

        guard let extractedVerticalMirror = extractedVerticalMirror else {
            throw SeiParseError.parseFailure("Vertical Mirror")
        }
        self.verticalMirror = extractedVerticalMirror == 0x01
    }
    
    func getBytes(_ data: ApplicationSeiData, startCode: Bool) -> Data {
        var bytes = Data(data.orientationSei)
        if !startCode {
            bytes.withUnsafeMutableBytes {
                $0.storeBytes(of: UInt32(data.orientationSei.count - H264Utilities.naluStartCode.count).byteSwapped, as: UInt32.self)
            }
        }
        bytes[data.getOrientationOffset(.orientation)] = self.orientation.rawValue
        bytes[data.getOrientationOffset(.mirror)] = self.verticalMirror ? 0x01 : 0x00
        return bytes
    }
    
    static func parse(encoded: Data, data: ApplicationSeiData) throws -> OrientationSei? {
        do {
            return try .init(encoded: encoded, data: data)
        } catch (SeiParseError.mismatch) {
            return nil
        } catch {
            throw error
        }
    }
}

struct TimestampSei {
    let timestamp: CMTime
    let sequenceNumber: UInt64
    let fps: UInt8
    
    init(timestamp: CMTime, sequenceNumber: UInt64, fps: UInt8) {
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.fps = fps
    }
    
    init(encoded: Data, data: ApplicationSeiData) throws {
        let idOffset = data.getTimestampOffset(.id)
        guard encoded.count == data.timestampSei.count,
              encoded[idOffset] == data.timestampSei[idOffset] else {
            throw SeiParseError.mismatch
        }

        var timeValue: Int64?
        var timeScale: Int32?
        var sequenceNumber: UInt64?
        encoded.withUnsafeBytes {
            timeValue = $0.loadUnaligned(fromByteOffset: data.getTimestampOffset(.timeValue), as: Int64.self).byteSwapped
            timeScale = $0.loadUnaligned(fromByteOffset: data.getTimestampOffset(.timeScale), as: Int32.self).byteSwapped
            sequenceNumber = $0.loadUnaligned(fromByteOffset: data.getTimestampOffset(.sequence), as: UInt64.self).byteSwapped
        }
        guard let timeValue = timeValue,
              let timeScale = timeScale else {
            throw SeiParseError.parseFailure("Timestamp")
        }
        self.timestamp = CMTimeMake(value: timeValue, timescale: timeScale)
        
        guard let sequenceNumber = sequenceNumber else {
            throw SeiParseError.parseFailure("Sequence")
        }
        self.sequenceNumber = sequenceNumber
        self.fps = encoded[data.getTimestampOffset(.fps)]
    }
    
    func getBytes(_ data: ApplicationSeiData, startCode: Bool) -> Data {
        var bytes = Data(data.timestampSei)
        let networkTimeValue = self.timestamp.value.bigEndian
        let networkTimeScale = self.timestamp.timescale.bigEndian
        let seq = self.sequenceNumber.bigEndian
        let fps = self.fps
        bytes.withUnsafeMutableBytes {
            if !startCode {
                $0.storeBytes(of: UInt32(data.timestampSei.count - H264Utilities.naluStartCode.count).byteSwapped, as: UInt32.self)
            }
            $0.storeBytes(of: networkTimeValue, toByteOffset: data.getTimestampOffset(.timeValue), as: Int64.self)
            $0.storeBytes(of: networkTimeScale, toByteOffset: data.getTimestampOffset(.timeScale), as: Int32.self)
            $0.storeBytes(of: seq, toByteOffset: data.getTimestampOffset(.sequence), as: UInt64.self)
            $0.storeBytes(of: fps, toByteOffset: data.getTimestampOffset(.fps), as: UInt8.self)
        }
        return bytes
    }
    
    static func parse(encoded: Data, data: ApplicationSeiData) throws -> TimestampSei? {
        do {
            return try .init(encoded: encoded, data: data)
        } catch (SeiParseError.mismatch) {
            return nil
        } catch {
            throw error
        }
    }
}

struct ApplicationSEI {
    let timestamp: TimestampSei?
    let orientation: OrientationSei?
}

class ApplicationSeiParser {
    private let data: ApplicationSeiData
    
    init(_ data: ApplicationSeiData) {
        self.data = data
    }
    
    func parse(encoded: Data) throws -> ApplicationSEI? {
        let timestamp = try TimestampSei.parse(encoded: encoded, data: self.data)
        let orientation = try OrientationSei.parse(encoded: encoded, data: self.data)
        if timestamp == nil && orientation == nil {
            return nil
        }
        return .init(timestamp: timestamp, orientation: orientation)
    }
}

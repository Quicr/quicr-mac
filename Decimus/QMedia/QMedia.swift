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

    /// Managed instance of QMedia.
    private var instance: UnsafeMutableRawPointer?

    /// Initialize a new instance of QMedia.
    /// - Parameter address: Address to connect to.
    /// - Parameter port: Port to connect on.
    init(address: URL, port: UInt16, protocol connectionProtocol: ProtocolType, conferenceId: UInt32) {
        MediaClient_Create(address.absoluteString,
                           port,
                           connectionProtocol.rawValue,
                           conferenceId,
                           &instance)
    }

    /// Destroy the instance of QMedia
    deinit {
        guard instance != nil else { return }
        MediaClient_Destroy(instance)
    }

    /// Signal the intent to publish a stream.
    /// - Parameter codec: The `CodecType` being published.
    /// - Returns Stream identifier to use for sending.
    func addStreamPublishIntent(mediaType: UInt8, clientId: UInt16) -> UInt64 {
        MediaClient_AddStreamPublishIntent(instance, mediaType, clientId)
    }

    /// Subscribe to an audio stream.
    /// - Parameter codec: The `CodecType` of interest.
    /// - Parameter callback: Function to run on receipt of data.
    /// - Returns The stream identifier subscribed to.
    func addStreamSubscribe(mediaType: UInt8, clientId: UInt16, callback: @escaping SubscribeCallback) -> UInt64 {
        MediaClient_AddStreamSubscribe(instance, mediaType, clientId, callback)
    }

    func removeMediaPublishStream(mediaStreamId: StreamIDType) {
        MediaClient_RemoveMediaPublishStream(instance, mediaStreamId)
    }

    func removeMediaSubscribeStream(mediaStreamId: StreamIDType) {
        MediaClient_RemoveMediaSubscribeStream(instance, mediaStreamId)
    }

    /// Send some audio data.
    /// - Parameter mediaStreamId: ID for this stream, returned from a `addAudioStreamPublishIntent` call.
    /// - Parameter buffer: Pointer to the audio data.
    /// - Parameter length: Length of the data in `buffer`.
    /// - Parameter timestamp: Timestamp of this audio data.
    func sendAudio(mediaStreamId: StreamIDType, buffer: UnsafePointer<UInt8>, length: UInt32, timestamp: UInt64) {
        MediaClient_sendAudio(instance, mediaStreamId, buffer, length, timestamp)
    }

    /// Send a video frame.
    /// - Parameter mediaStreamId: ID for this stream, returned from a `addVideoStreamPublishIntent` call.
    /// - Parameter buffer: Pointer to the video frame.
    /// - Parameter length: Length of the data in `buffer`.
    /// - Parameter timestamp: Timestamp of this video frame.
    /// - Parameter flag: True if the video frame being submitted is a keyframe.
    func sendVideoFrame(mediaStreamId: StreamIDType,
                        buffer: UnsafePointer<UInt8>,
                        length: UInt32,
                        timestamp: UInt64,
                        flag: Bool) {
        MediaClient_sendVideoFrame(instance, mediaStreamId, buffer, length, timestamp, flag)
    }

    enum GetStreamError: Error {
        case missing
        case malformed
    }

    /// Temporary method for parsing JSON to retrieve quality profiles for creating codecs.
    /// TODO: Remove this when QMedia's API is updated to accomodate this functionality
    private func getStreams(json: [String: Any], setName: String) throws -> [SourceIDType: [[String: String]]] {
        guard let sets = json[setName] as? [[String: Any]] else { throw GetStreamError.missing }

        var allProfiles: [SourceIDType: [[String: String]]] = [:]
        try sets.enumerated().forEach { index, json in
            guard let profileSet = json["profileSet"] as? [String: Any] else { throw GetStreamError.malformed }
            guard let profiles = profileSet["profiles"] as? [[String: String]] else { throw GetStreamError.malformed }
            guard let type = profileSet["type"] as? String else { throw GetStreamError.malformed }
            guard let mediaType = json["mediaType"] as? String else { throw GetStreamError.malformed }

            let sourceId = setName == "Publications" ?
            AVCaptureDevice.default(for: mediaType == "video" ? .video : .audio)!.uniqueID : String(index)

            if type == "singleordered" {
                allProfiles[sourceId] = [profiles[0]]
            } else if type == "simulcast" {
                if allProfiles[sourceId] == nil {
                    allProfiles[sourceId] = profiles
                } else {
                    allProfiles[sourceId]! += profiles
                }
            }
        }

        return allProfiles
    }

    /// Temporary method for parsing JSON to retrieve quality profiles for creating codecs.
    /// TODO: Remove this when QMedia's API is updated to accomodate this functionality
    func getStreamConfigs(_ manifest: String,
                          prepareEncoderCallback: (SourceIDType, UInt8, UInt16, String) -> Void,
                          prepareDecoderCallback: (SourceIDType, UInt8, UInt16, String) -> Void) throws {
        guard let manifestData = manifest.data(using: .utf8) else { fatalError() }
        guard let json = try? JSONSerialization.jsonObject(with: manifestData, options: []) as? [String: Any] else {
            throw GetStreamError.malformed
        }

        let setNames = ["Publications", "Subscriptions"]
        try setNames.forEach { setName in
            let allProfiles = try getStreams(json: json, setName: setName)
            let prepareCallback = setName == "Publications" ? prepareEncoderCallback : prepareDecoderCallback

            try allProfiles.forEach { sourceId, profiles in
                for profile in profiles {
                    guard let qualityProfile = profile["qualityProfile"] else { throw GetStreamError.malformed }
                    guard let quicrNamespaceUrl = profile["quicrNamespaceUrl"] else { throw GetStreamError.malformed }

                    guard let comp = URLComponents(string: quicrNamespaceUrl) else { throw GetStreamError.malformed }
                    let tokens = comp.path.components(separatedBy: "/")
                    let mediaType: UInt8 = UInt8(tokens[4]) ?? 0
                    let endpoint: UInt16 = UInt16(tokens[6]) ?? 0

                    prepareCallback(sourceId, mediaType, endpoint, qualityProfile)
                }
            }
        }
    }
}

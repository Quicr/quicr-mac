import Foundation
import AVFoundation

/// Swift Interface for using QMedia stack.
class MediaClient {
    /// Protocol type mappings
    enum ProtocolType: UInt8, CaseIterable { case UDP = 0; case QUIC = 1 }

    /// Managed instance of QMedia.
    private var instance: UnsafeMutableRawPointer?

    /// Initialize a new instance of QMedia.
    /// - Parameter address: Address to connect to.
    /// - Parameter port: Port to connect on.
    init(address: URL, port: UInt16, protocol connectionProtocol: ProtocolType) {
        MediaClient_Create(address.absoluteString, port, connectionProtocol.rawValue, &instance)
    }

    /// Destroy the instance of QMedia
    deinit {
        guard instance != nil else { return }
        MediaClient_Destroy(instance)
    }

    /// Signal the intent to publish a stream.
    /// - Parameter codec: The `CodecType` being published.
    /// - Returns Stream identifier to use for sending.
    func addStreamPublishIntent(conferenceId: UInt32, mediaType: UInt8, clientId: UInt16) -> UInt64 {
        MediaClient_AddStreamPublishIntent(instance, conferenceId, mediaType, clientId)
    }

    /// Subscribe to an audio stream.
    /// - Parameter codec: The `CodecType` of interest.
    /// - Parameter callback: Function to run on receipt of data.
    /// - Returns The stream identifier subscribed to.
    func addStreamSubscribe(conferenceId: UInt32, mediaType: UInt8, clientId: UInt16, callback: @escaping SubscribeCallback) -> UInt64 {
        MediaClient_AddStreamSubscribe(instance, conferenceId, mediaType, clientId, callback)
    }

    func removeMediaPublishStream(mediaStreamId: UInt64) {
        MediaClient_RemoveMediaPublishStream(instance, mediaStreamId)
    }

    func removeMediaSubscribeStream(mediaStreamId: UInt64) {
        MediaClient_RemoveMediaSubscribeStream(instance, mediaStreamId)
    }

    /// Send some audio data.
    /// - Parameter mediaStreamId: ID for this stream, returned from a `addAudioStreamPublishIntent` call.
    /// - Parameter buffer: Pointer to the audio data.
    /// - Parameter length: Length of the data in `buffer`.
    /// - Parameter timestamp: Timestamp of this audio data.
    func sendAudio(mediaStreamId: UInt64, buffer: UnsafePointer<UInt8>, length: UInt32, timestamp: UInt64) {
        MediaClient_sendAudio(instance, mediaStreamId, buffer, length, timestamp)
    }

    /// Send a video frame.
    /// - Parameter mediaStreamId: ID for this stream, returned from a `addVideoStreamPublishIntent` call.
    /// - Parameter buffer: Pointer to the video frame.
    /// - Parameter length: Length of the data in `buffer`.
    /// - Parameter timestamp: Timestamp of this video frame.
    /// - Parameter flag: True if the video frame being submitted is a keyframe.
    func sendVideoFrame(mediaStreamId: UInt64,
                        buffer: UnsafePointer<UInt8>,
                        length: UInt32,
                        timestamp: UInt64,
                        flag: Bool) {
        MediaClient_sendVideoFrame(instance, mediaStreamId, buffer, length, timestamp, flag)
    }

    /// Temporary method for parsing JSON to retrieve quality profiles for creating codecs.
    /// TODO: Remove this when QMedia's API is updated to accomodate this functionality
    private func getStreams(json: [String: Any], setName: String) -> [UInt64: [[String: String]]] {
        guard let sets = json[setName] as? [[String: Any]] else { fatalError("Couldn't get \(setName)") }

        var allProfiles: [UInt64: [[String: String]]] = [:]
        sets.enumerated().forEach { index, json in
            guard let profileSet = json["profileSet"] as? [String: Any] else { fatalError() }
            guard let profiles = profileSet["profiles"] as? [[String: String]] else { fatalError() }
            guard let type = profileSet["type"] as? String else { fatalError() }
            guard let mediaType = json["mediaType"] as? String else { fatalError() }

            let sourceId = setName == "Publications" ?
                AVCaptureDevice.default(for: mediaType == "video" ? .video : .audio)!.id : UInt64(index)

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
                          prepareEncoderCallback: (UInt64, UInt8, UInt16, CodecConfig) -> Void,
                          prepareDecoderCallback: (UInt64, UInt8, UInt16, CodecConfig) -> Void) {
        guard let manifestData = manifest.data(using: .utf8) else { fatalError() }
        guard let json = try? JSONSerialization.jsonObject(with: manifestData, options: []) as? [String: Any] else {
            fatalError("Couldn't parse JSON")
        }

        let setNames = ["Publications", "Subscriptions"]
        setNames.forEach { setName in
            let allProfiles = getStreams(json: json, setName: setName)
            let prepareCallback = setName == "Publications" ? prepareEncoderCallback : prepareDecoderCallback

            allProfiles.forEach { sourceId, profiles in
                for profile in profiles {
                    guard let qualityProfile = profile["qualityProfile"] else { fatalError() }
                    guard let quicrNamespaceUrl = profile["quicrNamespaceUrl"] else { fatalError() }

                    guard let comp = URLComponents(string: quicrNamespaceUrl) else { fatalError() }
                    let tokens = comp.path.components(separatedBy: "/")
                    let mediaType: UInt8 = UInt8(tokens[4]) ?? 0
                    let endpoint: UInt16 = UInt16(tokens[6]) ?? 0

                    let config = CodecFactory.makeCodecConfig(from: qualityProfile)
                    if config.codec == .av1 { continue }
                    prepareCallback(sourceId, mediaType, endpoint, config)
                }
            }
        }
    }
}

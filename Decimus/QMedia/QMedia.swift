import Foundation

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
    func addStreamPublishIntent(codec: UInt8, clientIdentifier: UInt16) -> UInt64 {
        // TODO: Update to generically named version of add stream
        MediaClient_AddAudioStreamPublishIntent(instance, codec, clientIdentifier)
    }

    /// Subscribe to an audio stream.
    /// - Parameter codec: The `CodecType` of interest.
    /// - Parameter callback: Function to run on receipt of data.
    /// - Returns The stream identifier subscribed to.
    func addStreamSubscribe(codec: CodecType, callback: @escaping SubscribeCallback) -> UInt64 {
        // TODO: Update to generically named version of add stream
        MediaClient_AddAudioStreamSubscribe(instance, codec.rawValue, callback)
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
}

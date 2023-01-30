import Foundation

/// Swift Interface for using QMedia stack.
class QMedia {

    /// Codec type mappings.
    enum CodecType: UInt8 { case h264 = 1; case opus = 2 }

    /// Managed instance of QMedia.
    private var instance: UnsafeMutableRawPointer?

    /// Initialize a new instance of QMedia.
    /// - Parameter address: Address to connect to.
    /// - Parameter port: Port to connect on.
    init(address: URL, port: UInt16) {
        MediaClient_Create(address.absoluteString, port, &instance)
    }

    /// Signal the intent to publish an audio stream.
    /// - Parameter codec: The `CodecType` being published.
    /// - Returns Stream identifier to use for `sendAudio`.
    func addAudioStreamPublishIntent(codec: CodecType) -> UInt64 {
         MediaClient_AddAudioStreamPublishIntent(instance, codec.rawValue)
    }

    /// Subscribe to an audio stream.
    /// - Parameter codec: The `CodecType` of interest.
    /// - Parameter callback: Function to run on receipt of audio data.
    /// - Returns The stream identifier subscribed to.
    func addAudioStreamSubscribe(codec: CodecType, callback: @escaping SubscribeCallback) -> UInt64 {
        MediaClient_AddAudioStreamSubscribe(instance, codec.rawValue, callback)
    }

    /// Signal the intent to publish a video stream.
    /// - Parameter codec: The `CodecType` being published.
    /// - Returns Stream identifier to use for `sendVideoFrame`.
    func addVideoStreamPublishIntent(codec: CodecType) -> UInt64 {
        MediaClient_AddVideoStreamPublishIntent(instance, codec.rawValue)
    }

    /// Subscribe to a video stream.
    /// - Parameter codec: The `CodecType` of interest.
    /// - Parameter callback: Function to run on receipt of video data.
    /// - Returns The stream identifier subscribed to.
    func addVideoStreamSubscribe(codec: CodecType, callback: SubscribeCallback) -> UInt64 {
        MediaClient_AddVideoStreamSubscribe(instance, codec.rawValue, callback)
    }

    func removeMediaStream(mediaStreamId: UInt64) {
        MediaClient_RemoveMediaStream(instance, mediaStreamId)
    }

    /// Send some audio data.
    /// - Parameter mediaStreamId: ID for this stream, returned from a `addAudioStreamPublishIntent` call.
    /// - Parameter buffer: Pointer to the audio data.
    /// - Parameter length: Length of the data in `buffer`.
    /// - Parameter timestamp: Timestamp of this audio data.
    func sendAudio(mediaStreamId: UInt64, buffer: UnsafePointer<UInt8>, length: UInt16, timestamp: UInt64) {
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
                        length: UInt16,
                        timestamp: UInt64,
                        flag: Bool) {
        MediaClient_sendVideoFrame(instance, mediaStreamId, buffer, length, timestamp, flag ? 1 : 0)
    }

    deinit {
        guard instance != nil else {return}
        MediaClient_Destroy(instance)
    }
}

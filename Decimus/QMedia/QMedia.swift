// TODO: This could be a Swift package?

import Foundation

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
    
    ///
    func addAudioStreamPublishIntent(codec: CodecType) -> UInt64 {
         MediaClient_AddAudioStreamPublishIntent(instance, codec.rawValue)
    }
    
    func addAudioStreamSubscribe(codec: CodecType, callback: @escaping SubscribeCallback) -> UInt64 {
        MediaClient_AddAudioStreamSubscribe(instance, codec.rawValue, callback)
    }
    
    func addVideoStreamPublishIntent(codec: CodecType) -> UInt64 {
        MediaClient_AddVideoStreamPublishIntent(instance, codec.rawValue)
    }
    
    func addVideoStreamSubscribe(codec: CodecType, callback: SubscribeCallback) -> UInt64 {
        MediaClient_AddVideoStreamSubscribe(instance, codec.rawValue, callback)
    }
    
    func removeMediaStream(mediaStreamId: UInt64) {
        MediaClient_RemoveMediaStream(instance, mediaStreamId)
    }
    
    func sendAudio(mediaStreamId: UInt64, buffer: UnsafePointer<UInt8>, length: UInt16, timestamp: UInt64) {
        MediaClient_sendAudio(instance, mediaStreamId, buffer, length, timestamp)
    }
    
    func sendVideoFrame(streamId: UInt64, buffer: UnsafePointer<UInt8>, length: UInt16, timestamp: UInt64, flag: Bool) {
        MediaClient_sendVideoFrame(instance, streamId, buffer, length, timestamp, flag ? 1 : 0)
    }
    
    deinit {
        guard instance != nil else {return}
        MediaClient_Destroy(instance)
    }
}

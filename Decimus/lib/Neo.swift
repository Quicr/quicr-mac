import Foundation

/// Swift bindings for Neo library.
/// TODO: Move to Swift package?
class Neo {
    var instance: UnsafeMutableRawPointer?
    
    init(address: URL, port: UInt16) {
        let logCallback: ExternalLogCallback = { message in
            guard message != nil else { return }
            print("[NEO] => \(message!)")
        }
        
        let newStreamCallback: NewStreamCallback = { client, source, startTime, sourceType in
            print("Got new stream")
        }
        // MediaClient_Create(logCallback, newStreamCallback, address.absoluteString, port, &instance)
    }
    
    func addAudioStream(domain: UInt64, conferenceId: UInt64, clientId: UInt64, mediaDirection: UInt8, sampleType: UInt8, sampleRate: UInt16, channels: UInt8) -> UInt64 {
        // MediaClient_AddAudioStream(instance, domain, conferenceId, clientId, mediaDirection, sampleType, sampleRate, channels)
        return 0
    }
    
    func addVideoStream(domain: UInt64, conferenceId: UInt64, clientId: UInt64, mediaDirection: UInt8, pixelFormat: UInt8, videoMaxWidth: UInt32, videoMaxHeight: UInt32, videoMaxFrameRate: UInt32, videoMaxBitrate: UInt32) -> UInt64 {
        // MediaClient_AddVideoStream(instance, domain, conferenceId, clientId, mediaDirection, pixelFormat, videoMaxWidth, videoMaxHeight, videoMaxFrameRate, videoMaxBitrate)
        return 0
    }
    
    func removeMediaStream(mediaStreamId: UInt64) {
        // MediaClient_RemoveMediaStream(instance, mediaStreamId)
    }
    
    func sendAudio(mediaStreamId: UInt64, buffer: UnsafePointer<UInt8>, length: UInt16, timestamp: UInt64) {
        // MediaClient_sendAudio(instance, mediaStreamId, buffer, length, timestamp)
    }
    
    struct AudioPacket {
        var timestamp: UInt64 = 0
        var buffer: UnsafeMutablePointer<UInt8>? = nil
        var toFree: UnsafeMutableRawPointer? = nil
        var length: Int32 = 0
    }
    	
    func getAudio(streamId: UInt64, maxLength: UInt32) -> AudioPacket {
        var packet: AudioPacket = .init()
        var read: Int32 = 0
        // read = MediaClient_getAudio(instance, streamId, &packet.timestamp, &packet.buffer, maxLength, &packet.toFree);
        packet.length = read
        return packet
    }
    
    func sendVideoFrame(streamId: UInt64, buffer: UnsafePointer<UInt8>, length: UInt32, width: UInt32, height: UInt32, strideY: UInt32, strideUV: UInt32, offsetU: UInt32, offsetV: UInt32, format: UInt32, timestamp: UInt64) {
        // MediaClient_sendVideoFrame(instance, streamId, buffer, length, width, height, strideY, strideUV, offsetU, offsetV, format, timestamp)
    }
    
    struct VideoFrame {
        var timestamp: UInt64 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var format: UInt32 = 0
        var buffer: UnsafeMutablePointer<UInt8>? = nil
        var toFree: UnsafeMutableRawPointer? = nil
        var length: UInt32 = 0
    }
    
    func getVideoFrame(streamId: UInt64) -> VideoFrame {
        var frame: VideoFrame = .init()
        var read: UInt32 = 0;
        // read = MediaClient_getVideoFrame(instance, streamId, &frame.timestamp, &frame.width, &frame.height, &frame.format, &frame.buffer, &frame.toFree)
        frame.length = read
        return frame
    }

    func releaseMediaBuffer(buffer: UnsafeMutableRawPointer) {
        // release_media_buffer(instance, buffer)
    }
    
    deinit {
        guard instance != nil else {return}
        // MediaClient_Destroy(instance)
    }
}

import Foundation
import AVFoundation

class Publication: NSObject,
                   AVCaptureVideoDataOutputSampleBufferDelegate,
                   AVCaptureAudioDataOutputSampleBufferDelegate {
    private(set) var device: AVCaptureDevice?
    private var encoder: Encoder?
    private var notifier: NotificationCenter = .default

    /// Prepare the device and encoder to start capturing and encoding.
    /// - Parameter sourceID: The unique ID of the source device
    /// - Parameter label: Label of the publication that can be displayed.
    /// - Parameter qualityProfile: The string of the quality profile for the codec to build.
    func prepare(sourceID: SourceIDType, label: String = "", qualityProfile: String) throws {
        self.device = AVCaptureDevice.init(uniqueID: sourceID)
        guard self.device != nil else {
            fatalError("[Publisher] Failed to find device for publication with id \(sourceID)")
        }

        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        do {
            try encoder = CodecFactory.shared.createEncoder(config) { [weak self] data in
                guard let self = self else { return }
                self.onEncode(data: data)
            }
            print("[Publisher] Registered \(String(describing: config.codec)) to publish stream: \(streamID)")
        } catch {
            print("[Publisher] Failed to create encoder: \(error)")
            throw error
        }

        notifier.post(name: .publicationPreparedForDevice, object: self)
    }

    // TODO: Remove once QMedia is updated to reflect the new arch.
    private unowned let client: MediaClient
    init(client: MediaClient) {
        self.client = client
    }

    private var streamID: StreamIDType = 0
    func prepare(streamID: StreamIDType, sourceID: SourceIDType, label: String = "", qualityProfile: String) throws {
        self.streamID = streamID
        try prepare(sourceID: sourceID, qualityProfile: qualityProfile)
    }

    /// This callback fires when a video frame arrives.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard connection.isEnabled else { return }
        guard let encoder = encoder else {
            fatalError("[Publisher] No encoder for Publisher. Did you forget to prepare?")
        }

        if device!.hasMediaType(.video) {
            encoder.write(data: sampleBuffer.asMediaBuffer())
        } else if device!.hasMediaType(.audio) {
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else {
                print("Couldn't get audio input format")
                return
            }

            guard asbd.mSampleRate == .opus48khz,
                  asbd.mChannelsPerFrame == 1,
                  asbd.mBytesPerFrame == 2 else {
                print("Microphone format not currently supported. Try a different mic")
                return
            }
            guard let formatDescription = sampleBuffer.formatDescription else {
                print("Missing format description")
                return
            }
            let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
            let data = sampleBuffer.getMediaBuffer(userData: audioFormat)
            encoder.write(data: data)
        }
    }

    /// This callback fires if a frame was dropped.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        var mode: CMAttachmentMode = 0
        let reason = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: &mode)

        print("Publication => Frame dropped! Reason: \(String(describing: reason))")
    }

    private func onEncode(data: MediaBuffer) {
        let buffer = data.buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let length: UInt32 = .init(data.buffer.count)
        let timestamp: UInt64 = .init(data.timestampMs)
        guard length > 0 else { return }

        if self.device!.hasMediaType(.audio) {
            self.client.sendAudio(mediaStreamId: streamID,
                                  buffer: buffer,
                                  length: length,
                                  timestamp: timestamp)
        } else if self.device!.hasMediaType(.video) {
            self.client.sendVideoFrame(mediaStreamId: streamID,
                                       buffer: buffer,
                                       length: length,
                                       timestamp: timestamp,
                                       flag: false)
        } else {
            fatalError("[Publisher] Failed encode: Unrecognized codec config")
        }
    }
    // end TODO
}

extension Notification.Name {
    static var publicationPreparedForDevice = Notification.Name("publicationPreparedForDevice")
}

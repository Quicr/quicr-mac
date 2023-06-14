import Foundation
import AVFoundation
import CoreAudio

class AudioSubscription: Subscription {

    struct Metrics {
        var framesEnqueued = 0
        var framesEnqueuedFail = 0
    }

    // TODO: This is temporary before we change QMedia
    private class Weak {
        weak var value: AudioSubscription?
        init(_ value: AudioSubscription?) { self.value = value }
    }
    private static var weakStaticSources: [StreamIDType: Weak] = [:]
    // end TODO

    private unowned let client: MediaClient
    private unowned let player: FasterAVEngineAudioPlayer
    init(client: MediaClient, player: FasterAVEngineAudioPlayer) {
        self.client = client
        self.player = player
    }

    deinit {
        self.client.removeMediaSubscribeStream(mediaStreamId: streamID)
        AudioSubscription.weakStaticSources.removeValue(forKey: streamID)
        self.player.removePlayer(identifier: streamID)

        // Reset source node.
        node?.reset()

        // Cleanup buffer.
        JitterDestroy(jitterBuffer)

        // Report metrics on leave.
        print("They had \(metrics.framesEnqueuedFail) copy fails")
    }

    private var streamID: StreamIDType = 0
    private var decoder: LibOpusDecoder?
    private var asbd: UnsafeMutablePointer<AudioStreamBasicDescription> = .allocate(capacity: 1)
    private var metrics: Metrics = .init()
    private var node: AVAudioSourceNode?
    private var jitterBuffer: UnsafeMutableRawPointer?
    private var seq: UInt = 0

    func prepare(streamID: StreamIDType, sourceID: SourceIDType, qualityProfile: String) throws {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        self.streamID = streamID

        do {
            decoder = try .init(format: player.inputFormat)
        } catch {
            let format: AVAudioFormat.OpusPCMFormat
            switch player.inputFormat.commonFormat {
            case .pcmFormatFloat32:
                format = .float32
            case .pcmFormatInt16:
                format = .int16
            default:
                fatalError()
            }
            do {
                decoder = try .init(format: .init(opusPCMFormat: format,
                                                  sampleRate: 48000,
                                                  channels: player.inputFormat.channelCount)!)
            } catch {
                fatalError()
            }
        }

        decoder!.registerCallback(callback: { buffer, _ in
            // Ensure this buffer looks valid.
            let list = buffer.audioBufferList
            guard list.pointee.mNumberBuffers == 1 else {
                fatalError()
            }
            guard list.pointee.mBuffers.mDataByteSize > 0 else {
                fatalError()
            }

            // Get audio data as packet list.
            let audioBuffer = list.pointee.mBuffers
            var packet: Packet = .init(sequence_number: self.seq,
                                       data: audioBuffer.mData,
                                       length: Int(audioBuffer.mDataByteSize),
                                       elements: Int(buffer.frameLength))
            self.seq += 1

            // Copy in.
            let copied = JitterEnqueue(self.jitterBuffer, &packet, 1, self.plcCallback)
            self.metrics.framesEnqueued += copied
            guard copied == buffer.frameLength else {
                print("Only managed to enqueue: \(copied)/\(buffer.frameLength)")
                let missing = Int(buffer.frameLength) - copied
                self.metrics.framesEnqueuedFail += missing
                return
            }
        })

        // TODO: Make jitter configuration available in settings.
        jitterBuffer = JitterInit(Int(decoder!.decodedFormat.streamDescription.pointee.mBytesPerPacket),
                                  UInt(decoder!.decodedFormat.sampleRate),
                                  20,
                                  500)
        guard jitterBuffer != nil else {
            fatalError()
        }

        // Create the player node.
        asbd = .init(mutating: decoder!.decodedFormat.streamDescription)
        node = .init(format: decoder!.decodedFormat) { [jitterBuffer, asbd] silence, _, numFrames, data in
            // Fill the buffers as best we can.
            guard data.pointee.mNumberBuffers == 1 else {
                fatalError("What to do")
            }

            guard data.pointee.mBuffers.mNumberChannels == asbd.pointee.mChannelsPerFrame else {
                fatalError("Channel mismatch")
            }

            let buffer: AudioBuffer = data.pointee.mBuffers
            assert(buffer.mDataByteSize == numFrames * asbd.pointee.mBytesPerFrame)
            let copiedFrames = JitterDequeue(jitterBuffer, buffer.mData, Int(buffer.mDataByteSize), Int(numFrames))
            guard copiedFrames == numFrames else {
                // Ensure any incomplete data is pure silence.
                let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
                for buffer in buffers {
                    guard let dataPointer = buffer.mData else {
                        break
                    }
                    let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
                    let discontinuityStartOffset = copiedFrames * bytesPerFrame
                    let numberOfSilenceBytes = (Int(numFrames) - copiedFrames) * bytesPerFrame
                    guard discontinuityStartOffset + numberOfSilenceBytes == buffer.mDataByteSize else {
                        print("[FasterAVEngineAudioPlayer] Invalid buffers when calculating silence")
                        break
                    }
                    memset(dataPointer + discontinuityStartOffset, 0, Int(numberOfSilenceBytes))
                    let thisBufferSilence = numberOfSilenceBytes == buffer.mDataByteSize
                    let silenceSoFar = silence.pointee.boolValue
                    silence.pointee = .init(thisBufferSilence && silenceSoFar)
                }
                return .zero
            }
            return .zero
        }

        self.player.addPlayer(identifier: streamID, node: node!)

        // TODO: This is temporary before we change QMedia
        AudioSubscription.weakStaticSources[streamID] = .init(self)

        print("[AudioSubscription] Subscribed to \(String(describing: config.codec)) stream: \(streamID)")
    }

    let plcCallback: LibJitterConcealmentCallback = { packets, count in
        for index in 0...count-1 {
            // Make PLC packets.
            // TODO: Ask the opus decoder to generate real PLC data.
            let packetPtr = packets!.advanced(by: index)
            print("[AudioSubscription] Requested PLC for: \(packetPtr.pointee.sequence_number)")
            let malloced = malloc(480 * 8)
            memset(malloced, 0, 480 * 8)
            packetPtr.pointee.data = .init(malloced)
            packetPtr.pointee.elements = 480
            packetPtr.pointee.length = 480 * 8
        }
    }

    let subscribedObject: SubscribeCallback = { streamId, _, _, data, length, timestamp in
        guard let subscriber = AudioSubscription.weakStaticSources[streamId]?.value else {
            fatalError("[Subscriber:\(streamId)] Failed to find instance for stream")
        }

        guard data != nil else {
            print("[Subscriber:\(streamId)] Data was nil")
            return
        }

        subscriber.write(data: .init(buffer: .init(start: data, count: Int(length)),
                                     timestampMs: UInt32(timestamp)))
    }

    private func write(data: MediaBuffer) {
        guard let decoder = decoder else {
            fatalError("[Subscriber:\(streamID)] No decoder for Subscriber. Did you forget to prepare?")
        }
        decoder.write(buffer: data)
    }
}

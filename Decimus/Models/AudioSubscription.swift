import Foundation
import AVFoundation
import CTPCircularBuffer
import CoreAudio

class AudioSubscription: Subscription {

    struct Metrics {
        var copyFails = 0
        var copyAttempts = 0
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
        TPCircularBufferCleanup(buffer)

        // Report metrics on leave.
        print("They had \(metrics.copyFails)/\(metrics.copyAttempts) copy fails")
    }

    private var streamID: StreamIDType = 0
    private var decoder: LibOpusDecoder?
    private var buffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private var asbd: UnsafeMutablePointer<AudioStreamBasicDescription> = .allocate(capacity: 1)
    private var metrics: Metrics = .init()
    private var node: AVAudioSourceNode?

    func prepare(streamID: StreamIDType, sourceID: SourceIDType, qualityProfile: String) throws {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile)
        self.streamID = streamID

        do {
            decoder = try .init(format: player.inputFormat)
        } catch {
            do {
                decoder = try .init(format: .init(opusPCMFormat: .float32, sampleRate: 48000, channels: 2)!)
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

            // Copy in.
            let copied = TPCircularBufferCopyAudioBufferList(self.buffer,
                                                             list,
                                                             nil,
                                                             kTPCircularBufferCopyAll,
                                                             nil)
            self.metrics.copyAttempts += 1
            guard copied else {
                self.metrics.copyFails += 1
                return
            }
        })

        // Create the circular buffer with minimum size.
        let created = _TPCircularBufferInit(buffer,
                                            1,
                                            MemoryLayout<TPCircularBuffer>.size)
        guard created else {
            fatalError()
        }

        // Create the player node.
        asbd = .init(mutating: decoder!.decodedFormat.streamDescription)
        node = .init(format: decoder!.decodedFormat) { [buffer, asbd] silence, timestamp, numFrames, data in
            // Fill the buffers as best we can.
            var copiedFrames: UInt32 = numFrames
            TPCircularBufferDequeueBufferListFrames(buffer,
                                                    &copiedFrames,
                                                    data,
                                                    .init(mutating: timestamp),
                                                    asbd)
            guard copiedFrames == numFrames else {
                // Ensure any incomplete data is pure silence.
                let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
                for buffer in buffers {
                    guard let dataPointer = buffer.mData else {
                        break
                    }
                    let discontinuityStartOffset = Int(copiedFrames * asbd.pointee.mBytesPerFrame)
                    let numberOfSilenceBytes = Int((numFrames - copiedFrames) * asbd.pointee.mBytesPerFrame)
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

import AVFAudio
import CoreAudio

// swiftlint:disable identifier_name
enum OpusSubscriptionError: Error {
    case FailedDecoderCreation
}
// swiftlint:enable identifier_name

actor OpusSubscriptionMeasurement: Measurement {
    var name: String = "OpusSubscription"
    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    private var frames: UInt64 = 0
    private var bytes: UInt64 = 0
    private var missing: UInt64 = 0

    init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
        tags["namespace"] = namespace
        Task {
            await submitter.register(measurement: self)
        }
    }

    func receivedFrames(received: AVAudioFrameCount, timestamp: Date?) {
        self.frames += UInt64(received)
        record(field: "receivedFrames", value: self.frames as AnyObject, timestamp: timestamp)
    }

    func receivedBytes(received: UInt, timestamp: Date?) {
        self.bytes += UInt64(received)
        record(field: "receivedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
    }

    func missingSeq(missingCount: UInt64, timestamp: Date?) {
        self.missing += missingCount
        record(field: "missingSeqs", value: self.missing as AnyObject, timestamp: timestamp)
    }
}

class OpusSubscription: Subscription {
    struct Metrics {
        var framesEnqueued = 0
        var framesEnqueuedFail = 0
    }

    let namespace: String
    private var decoder: LibOpusDecoder

    private unowned let player: FasterAVEngineAudioPlayer
    private var asbd: UnsafeMutablePointer<AudioStreamBasicDescription> = .allocate(capacity: 1)
    private var metrics: Metrics = .init()
    private var node: AVAudioSourceNode?
    private var jitterBuffer: UnsafeMutableRawPointer?
    private var seq: UInt32 = 0
    private let measurement: OpusSubscriptionMeasurement

    init(namespace: QuicrNamespace,
         player: FasterAVEngineAudioPlayer,
         config: AudioCodecConfig,
         submitter: MetricsSubmitter) throws {
        self.namespace = namespace
        self.player = player
        self.measurement = .init(namespace: namespace, submitter: submitter)
        do {
            self.decoder = try OpusSubscription.createOpusDecoder(config: config, player: player)
            self.decoder.registerCallback { [weak self] in
                self?.onDecodedAudio(buffer: $0, timestamp: $1)
            }
        } catch {
            throw OpusSubscriptionError.FailedDecoderCreation
        }

        // Create the jitter buffer.
        asbd = .init(mutating: decoder.decodedFormat.streamDescription)
        jitterBuffer = JitterInit(Int(asbd.pointee.mBytesPerPacket),
                                  UInt(asbd.pointee.mSampleRate),
                                  500,
                                  20)

        // Create the player node.
        node = .init(format: decoder.decodedFormat, renderBlock: renderBlock)

        self.player.addPlayer(identifier: namespace, node: node!)
        log("Subscribed to OPUS stream")
    }

    deinit {
        // Remove the audio playout.
        player.removePlayer(identifier: namespace)

        // Reset the node.
        node?.reset()

        // Cleanup buffer.
        JitterDestroy(jitterBuffer)

        // Report metrics.
        print("They had \(metrics.framesEnqueuedFail) copy fails")
    }

    func prepare(_ sourceID: SourceIDType!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.None.rawValue
    }

    private lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [jitterBuffer, asbd] silence, _, numFrames, data in
        // Fill the buffers as best we can.
        guard data.pointee.mNumberBuffers == 1 else {
            fatalError("What to do")
        }

        guard data.pointee.mBuffers.mNumberChannels == asbd.pointee.mChannelsPerFrame else {
            fatalError("Channel mismatch")
        }

        guard jitterBuffer != nil else {
            fatalError("JitterBuffer should exist at this point")
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

    private let plcCallback: LibJitterConcealmentCallback = { packets, count, _ in
        for index in 0...count - 1 {
            // Make PLC packets.
            // TODO: Ask the opus deco5der to generate real PLC data.
            // TODO: Figure out how to best pass in frame lengths and sizes.
            let packetPtr = packets!.advanced(by: index)
            print("[AudioSubscription] Requested PLC for: \(packetPtr.pointee.sequence_number)")
            let malloced = malloc(480 * 8)
            memset(malloced, 0, 480 * 8)
            packetPtr.pointee.data = .init(malloced)
            packetPtr.pointee.elements = 480
            packetPtr.pointee.length = 480 * 8
        }
    }

    private let freeCallback: LibJitterConcealmentCallback = { packets, count, _ in
        for index in 0...count - 1 {
            let packetPtr = packets!.advanced(by: index)
            free(.init(mutating: packetPtr.pointee.data))
        }
    }

    private static func createOpusDecoder(config: CodecConfig, player: FasterAVEngineAudioPlayer) throws -> LibOpusDecoder {
        guard config.codec == .opus else {
            fatalError("Codec mismatch")
        }

        do {
            // First, try and decode directly into the output's input format.
            return try .init(format: player.inputFormat)
        } catch {
            // That may not be supported, so decode into standard output instead.
            let format: AVAudioFormat.OpusPCMFormat
            switch player.inputFormat.commonFormat {
            case .pcmFormatInt16:
                format = .int16
            case .pcmFormatFloat32:
                format = .float32
            default:
                fatalError()
            }
            return try .init(format: .init(opusPCMFormat: format,
                                           sampleRate: 48000,
                                           channels: player.inputFormat.channelCount)!)
        }
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.NoDecoder.rawValue
    }

    func subscribedObject(_ data: Data!, groupId: UInt32, objectId: UInt16) -> Int32 {
        // Metrics.
        let date = Date.now
        let missing = groupId - self.seq - 1
        let currentSeq = self.seq
        Task(priority: .utility) {
            await measurement.receivedBytes(received: UInt(data.count), timestamp: date)
            if missing > 0 {
                print("LOSS! \(missing) packets. Had: \(currentSeq), got: \(groupId)")
                await measurement.missingSeq(missingCount: UInt64(missing), timestamp: date)
            }
        }

        self.seq = groupId
        data.withUnsafeBytes {
            decoder.write(data: $0, timestamp: .init(Date.now.timeIntervalSince1970))
        }
        return SubscriptionError.None.rawValue
    }

    private func onDecodedAudio(buffer: AVAudioPCMBuffer, timestamp: CMTime?) {
        // Ensure this buffer looks valid.
        let list = buffer.audioBufferList
        guard list.pointee.mNumberBuffers == 1 else {
            fatalError()
        }
        guard list.pointee.mBuffers.mDataByteSize > 0 else {
            fatalError()
        }

        Task(priority: .utility) {
            var date: Date?
            if let timestamp = timestamp {
                date = .init(timeIntervalSince1970: timestamp.seconds)
            }
            await measurement.receivedFrames(received: buffer.frameLength, timestamp: date)
        }

        // Get audio data as packet list.
        let audioBuffer = list.pointee.mBuffers
        var packet: Packet = .init(sequence_number: UInt(self.seq),
                                   data: audioBuffer.mData,
                                   length: Int(audioBuffer.mDataByteSize),
                                   elements: Int(buffer.frameLength))

        // Copy in.
        let copied = JitterEnqueue(self.jitterBuffer, &packet, 1, self.plcCallback, self.freeCallback, nil)
        self.metrics.framesEnqueued += copied
        guard copied == buffer.frameLength else {
            print("Only managed to enqueue: \(copied)/\(buffer.frameLength)")
            let missing = Int(buffer.frameLength) - copied
            self.metrics.framesEnqueuedFail += missing
            return
        }
    }
}
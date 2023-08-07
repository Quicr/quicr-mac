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
    private var callbacks: UInt64 = 0

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

    func framesUnderrun(underrun: UInt64, timestamp: Date?) {
        record(field: "framesUnderrun", value: underrun as AnyObject, timestamp: timestamp)
    }

    func concealmentFrames(concealed: UInt64, timestamp: Date?) {
        record(field: "framesConcealed", value: concealed as AnyObject, timestamp: timestamp)
    }

    func callbacks(callbacks: UInt64, timestamp: Date?) {
        record(field: "callbacks", value: callbacks as AnyObject, timestamp: timestamp)
    }
}

class OpusSubscription: Subscription {
    struct Metrics {
        var framesEnqueued = 0
        var framesEnqueuedFail = 0
    }

    private class Weak<T> {
        var value: T
        init(value: T) {
            self.value = value
        }
    }

    let namespace: String
    private var decoder: LibOpusDecoder

    private unowned let player: FasterAVEngineAudioPlayer
    private var asbd: UnsafeMutablePointer<AudioStreamBasicDescription> = .allocate(capacity: 1)
    private var metrics: Metrics = .init()
    private var node: AVAudioSourceNode?
    private let errorWriter: ErrorWriter
    private var jitterBuffer: QJitterBuffer
    private var seq: UInt32 = 0
    private let measurement: OpusSubscriptionMeasurement
    private var underrun: Weak<UInt64> = .init(value: 0)
    private var callbacks: Weak<UInt64> = .init(value: 0)

    init(namespace: QuicrNamespace,
         player: FasterAVEngineAudioPlayer,
         config: AudioCodecConfig,
         submitter: MetricsSubmitter,
         errorWriter: ErrorWriter) throws {
        self.namespace = namespace
        self.player = player
        self.errorWriter = errorWriter
        self.measurement = .init(namespace: namespace, submitter: submitter)

        do {
            self.decoder = try OpusSubscription.createOpusDecoder(config: config, player: player)
        } catch {
            throw OpusSubscriptionError.FailedDecoderCreation
        }

        // Create the jitter buffer.
        self.asbd = .init(mutating: decoder.decodedFormat.streamDescription)
        self.jitterBuffer = QJitterBuffer(elementSize: Int(asbd.pointee.mBytesPerPacket),
                                          packetElements: 480,
                                          clockRate: UInt(asbd.pointee.mSampleRate),
                                          maxLengthMs: 500,
                                          minLengthMs: 20)

        // Create the player node.
        self.node = .init(format: decoder.decodedFormat, renderBlock: renderBlock)
        try self.player.addPlayer(identifier: namespace, node: node!)

        log("Subscribed to OPUS stream")
    }

    deinit {
        // Remove the audio playout.
        player.removePlayer(identifier: namespace)

        // Reset the node.
        node?.reset()

        // Report metrics.
        log("They had \(metrics.framesEnqueuedFail) copy fails")
    }

    func prepare(_ sourceID: SourceIDType!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.None.rawValue
    }

    private lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [jitterBuffer, asbd, weak underrun, weak callbacks] silence, _, numFrames, data in
        // Fill the buffers as best we can.
        if let callbacks = callbacks {
            callbacks.value += 1
        }
        guard data.pointee.mNumberBuffers == 1 else {
            // Unexpected.
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            print("Got multiple buffers?")
            for buffer in buffers {
                print("Got buffer of size: \(buffer.mDataByteSize), channels: \(buffer.mNumberChannels)")
            }
            return 1
        }

        guard data.pointee.mBuffers.mNumberChannels == asbd.pointee.mChannelsPerFrame else {
            print("Unexpected render block channels. Got \(data.pointee.mBuffers.mNumberChannels). Expected \(asbd.pointee.mChannelsPerFrame)")
            return 1
        }

        let buffer: AudioBuffer = data.pointee.mBuffers
        assert(buffer.mDataByteSize == numFrames * asbd.pointee.mBytesPerFrame)
        let copiedFrames = jitterBuffer.dequeue(buffer.mData,
                                                destinationLength: Int(buffer.mDataByteSize),
                                                elements: Int(numFrames))
        guard copiedFrames == numFrames else {
            // Ensure any incomplete data is pure silence.
            let framesUnderan = UInt64(numFrames) - UInt64(copiedFrames)
            if let underrun = underrun {
                underrun.value += framesUnderan
            }
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            for buffer in buffers {
                guard let dataPointer = buffer.mData else {
                    break
                }
                let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
                let discontinuityStartOffset = copiedFrames * bytesPerFrame
                let numberOfSilenceBytes = Int(framesUnderan) * bytesPerFrame
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

    private let plcCallback: PacketCallback = { packets, count, userData in
        guard let userData = userData else {
            print("Expected self in userData")
            return
        }
        let subscription: OpusSubscription = Unmanaged<OpusSubscription>.fromOpaque(userData).takeUnretainedValue()
        var concealed: UInt64 = 0
        for index in 0..<count {
            // Make PLC packets.
            var packet = packets!.advanced(by: index)
            do {
                // TODO: This can be optimized with some further work to decode PLC directly into the buffer.
                let plcData = try subscription.decoder.plc(frames: AVAudioFrameCount(packet.pointee.elements))
                let list = plcData.audioBufferList
                guard list.pointee.mNumberBuffers == 1 else {
                    throw "Not sure what to do with this"
                }

                // Get audio data as packet list.
                let audioBuffer = list.pointee.mBuffers
                guard let data = audioBuffer.mData else {
                    throw "AudioBuffer data was nil"
                }
                assert(packet.pointee.length == audioBuffer.mDataByteSize)
                memcpy(packet.pointee.data, data, packet.pointee.length)
                concealed += UInt64(packet.pointee.elements)
            } catch {
                print(error.localizedDescription)
            }
        }
        let constConcealed = concealed
        Task(priority: .utility) {
            await subscription.measurement.concealmentFrames(concealed: constConcealed, timestamp: nil)
        }
    }

    private static func createOpusDecoder(config: CodecConfig,
                                          player: FasterAVEngineAudioPlayer) throws -> LibOpusDecoder {
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

        // TODO: Handle sequence rollover.
        if groupId > self.seq {
            let missing = groupId - self.seq - 1
            let currentSeq = self.seq
            Task(priority: .utility) {
                await measurement.receivedBytes(received: UInt(data.count), timestamp: date)
                if missing > 0 {
                    log("LOSS! \(missing) packets. Had: \(currentSeq), got: \(groupId)")
                    await measurement.missingSeq(missingCount: UInt64(missing), timestamp: date)
                }
                await measurement.framesUnderrun(underrun: self.underrun.value, timestamp: date)
                await measurement.callbacks(callbacks: self.callbacks.value, timestamp: date)
            }
            self.seq = groupId
        }

        var decoded: AVAudioPCMBuffer?
        let result: SubscriptionError = data.withUnsafeBytes {
            do {
                decoded = try decoder.write(data: $0)
                return SubscriptionError.None
            } catch {
                let message = "Failed to write to decoder: \(error.localizedDescription)"
                log(message)
                errorWriter.writeError(message)
                return SubscriptionError.NoDecoder
            }
        }
        guard result == .None else { return result.rawValue }
        do {
            try queueDecodedAudio(buffer: decoded!, timestamp: date, sequence: groupId)
        } catch {
            errorWriter.writeError("Failed to enqueue decoded audio for playout: \(error.localizedDescription)")
        }
        return SubscriptionError.None.rawValue
    }

    private func queueDecodedAudio(buffer: AVAudioPCMBuffer, timestamp: Date, sequence: UInt32) throws {
        // Ensure this buffer looks valid.
        let list = buffer.audioBufferList
        guard list.pointee.mNumberBuffers == 1 else {
            throw "Unexpected number of buffers"
        }

        Task(priority: .utility) {
            await measurement.receivedFrames(received: buffer.frameLength, timestamp: timestamp)
        }

        // Get audio data as packet list.
        let audioBuffer = list.pointee.mBuffers
        guard let data = audioBuffer.mData else {
            log("AudioBuffer data was nil")
            return
        }

        var packet: Packet = .init(sequence_number: UInt(sequence),
                                   data: data,
                                   length: Int(audioBuffer.mDataByteSize),
                                   elements: Int(buffer.frameLength))

        let selfPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()

        // Copy in.
        let copied = jitterBuffer.enqueue(packet,
                                          concealmentCallback: self.plcCallback,
                                          userData: selfPtr)
        self.metrics.framesEnqueued += copied
        guard copied >= buffer.frameLength else {
            assert(copied % Int(buffer.frameLength) == 0)
            errorWriter.writeError("Only managed to enqueue: \(copied)/\(buffer.frameLength)")
            log("Only managed to enqueue: \(copied)/\(buffer.frameLength)")
            let missing = Int(buffer.frameLength) - copied
            self.metrics.framesEnqueuedFail += missing
            return
        }
    }
}

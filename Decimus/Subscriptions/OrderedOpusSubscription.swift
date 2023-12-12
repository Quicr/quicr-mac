import AVFAudio
import CoreAudio
import os
import CTPCircularBuffer

class OrderedOpusSubscription: QSubscriptionDelegateObjC {
    private static let logger = DecimusLogger(OrderedOpusSubscription.self)

    private let sourceId: SourceIDType
    private var decoder: LibOpusDecoder
    private let engine: DecimusAudioEngine
    private var asbd: UnsafeMutablePointer<AudioStreamBasicDescription> = .allocate(capacity: 1)
    private var metrics: Metrics = .init()
    private var node: AVAudioSourceNode?
    private var jitterBuffer: JitterBuffer
    private var seq: UInt32 = 0
    private let measurement: OpusSubscriptionMeasurement?
    private var underrun: Wrapped<UInt64> = .init(0)
    private var callbacks: Wrapped<UInt64> = .init(0)
    private let reliable: Bool
    private let granularMetrics: Bool
    private var decodeTask: Task<(), Never>?
    private var lastReadSeq: UInt64?
    private let renderBuffer: UnsafeMutablePointer<TPCircularBuffer> = .allocate(capacity: 1)
    private let opusWindowSize: OpusWindowSize

    init(sourceId: SourceIDType,
         profileSet: QClientProfileSet,
         engine: DecimusAudioEngine,
         submitter: MetricsSubmitter?,
         jitterDepth: TimeInterval,
         jitterMax: TimeInterval,
         opusWindowSize: OpusWindowSize,
         reliable: Bool,
         granularMetrics: Bool) throws {
        self.sourceId = sourceId
        self.engine = engine
        if let submitter = submitter {
            self.measurement = .init(namespace: sourceId, submitter: submitter)
        } else {
            self.measurement = nil
        }
        self.opusWindowSize = opusWindowSize
        self.reliable = reliable
        self.granularMetrics = granularMetrics

        do {
            self.decoder = try .init(format: DecimusAudioEngine.format)
        } catch {
            throw OpusSubscriptionError.FailedDecoderCreation
        }

        // Create the jitter buffer.
        self.asbd = .init(mutating: decoder.decodedFormat.streamDescription)
        self.jitterBuffer = try .init(namespace: sourceId,
                                      frameDuration: opusWindowSize.rawValue,
                                      metricsSubmitter: submitter,
                                      sort: reliable,
                                      minDepth: jitterDepth)

        // Create the render buffer.
        let format = DecimusAudioEngine.format
        let hundredMils = Double(format.streamDescription.pointee.mBytesPerPacket) * format.sampleRate * opusWindowSize.rawValue
        guard _TPCircularBufferInit(renderBuffer, UInt32(hundredMils), MemoryLayout<TPCircularBuffer>.size) else {
            fatalError()
        }

        // Create the player node.
        self.node = .init(format: decoder.decodedFormat, renderBlock: renderBlock)
        try self.engine.addPlayer(identifier: sourceId, node: node!)
        
        // Decode task.
        self.decodeTask = .init(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                var depth = self.jitterBuffer.getDepth()
                while depth > jitterDepth {
                    // Decode and copy to render buffer.
                    var decodedAudio: [AVAudioPCMBuffer] = []
                    guard let encoded = self.jitterBuffer.read() else {
                        // TODO: Report an underrun.
                        break
                    }
                    
                    // We've got an encoded packet, is there a gap?
                    guard let seq = encoded.getSequenceNumber() else {
                        // We should always get a sequence number.
                        fatalError()
                    }

                    if let lastReadSeq = self.lastReadSeq {
                        // If we got something prior to previous read,
                        // it's too late, skip.
                        guard seq > lastReadSeq else {
                            continue
                        }

                        // Is there any discontinuity?
                        if lastReadSeq + 1 != seq {
                            let missing = seq - lastReadSeq - 1
                            print("PLC: \(missing)")
                            // There's a gap! We should PLC.
                            do {
                                let plc = try self.decoder.plc(frames: 960 * UInt32(missing))
                                decodedAudio.append(plc)
                                self.jitterBuffer.lastSequenceRead = seq - 1
                            } catch {
                                Self.logger.error("Failed to generate PLC frames: \(error.localizedDescription)")
                            }
                        }
                    }

                    self.lastReadSeq = seq
                    assert(encoded.dataBuffer!.isContiguous)
                    do {
                        try encoded.dataBuffer!.withUnsafeMutableBytes(atOffset: 0) {
                            let data = Data(bytesNoCopy: $0.baseAddress!, count: $0.count, deallocator: .none)
                            decodedAudio.append(try! self.decoder.write(data: data))
                        }
                   } catch {
                       Self.logger.error("Couldn't access encoded audio data buffer: \(error.localizedDescription)")
                   }
                    
                   var ts = AudioTimeStamp()
                   for decoded in decodedAudio.reversed() {
                       TPCircularBufferCopyAudioBufferList(self.renderBuffer,
                                                           decoded.audioBufferList,
                                                           &ts,
                                                           decoded.frameLength,
                                                           self.decoder.decodedFormat.streamDescription)
                   }
                }
                depth = self.jitterBuffer.getDepth()
                try? await Task.sleep(for: .seconds(opusWindowSize.rawValue),
                                      tolerance: .seconds(opusWindowSize.rawValue / 2),
                                      clock: .continuous)
            }
        }

        Self.logger.info("Subscribed to OPUS stream")
    }

    deinit {
        self.decodeTask?.cancel()
        // Remove the audio playout.
        do {
            try engine.removePlayer(identifier: sourceId)
        } catch {
            Self.logger.critical("Couldn't remove player: \(error.localizedDescription)")
        }

        // Reset the node.
        node?.reset()
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 profileSet: QClientProfileSet,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        return SubscriptionError.none.rawValue
    }

    private lazy var renderBlock: AVAudioSourceNodeRenderBlock = { [jitterBuffer, asbd, weak underrun, weak callbacks] silence, _, numFrames, data in
        // Fill the buffers as best we can.
        if let callbacks = callbacks {
            callbacks.value += UInt64(numFrames)
        }

        guard data.pointee.mNumberBuffers == 1 else {
            // Unexpected.
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            Self.logger.error("Got multiple buffers: \(data.pointee.mNumberBuffers)")
            for (idx, buffer) in buffers.enumerated() {
                Self.logger.error("Buffer \(idx) size: \(buffer.mDataByteSize), channels: \(buffer.mNumberChannels)")
            }
            return 1
        }

        guard data.pointee.mBuffers.mNumberChannels == asbd.pointee.mChannelsPerFrame else {
            Self.logger.error("Unexpected render block channels. Got \(data.pointee.mBuffers.mNumberChannels). Expected \(asbd.pointee.mChannelsPerFrame)")
            return 1
        }

        var copiedFrames = numFrames
        var timestamp = AudioTimeStamp()
        TPCircularBufferDequeueBufferListFrames(self.renderBuffer,
                                                &copiedFrames,
                                                data,
                                                &timestamp,
                                                asbd)
        guard copiedFrames == numFrames else {
            // Ensure any incomplete data is pure silence.
            let framesUnderan = UInt64(numFrames) - UInt64(copiedFrames)
            silence.pointee = .init(framesUnderan == numFrames)
            if let underrun = underrun {
                underrun.value += framesUnderan
            }
            let buffers: UnsafeMutableAudioBufferListPointer = .init(data)
            for buffer in buffers {
                guard let dataPointer = buffer.mData else {
                    break
                }
                let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
                let discontinuityStartOffset = copiedFrames * UInt32(bytesPerFrame)
                let numberOfSilenceBytes = Int(framesUnderan) * bytesPerFrame
                guard discontinuityStartOffset + UInt32(numberOfSilenceBytes) == buffer.mDataByteSize else {
                    Self.logger.error("Invalid buffers when calculating silence")
                    break
                }
                memset(dataPointer + UnsafeMutableRawPointer.Stride(discontinuityStartOffset), 0, Int(numberOfSilenceBytes))
            }
            return .zero
        }
        return .zero
    }

    func update(_ sourceId: SourceIDType!, label: String!, profileSet: QClientProfileSet) -> Int32 {
        return SubscriptionError.noDecoder.rawValue
    }

    func subscribedObject(_ name: String!,
                          data: UnsafeRawPointer!,
                          length: Int,
                          groupId: UInt32,
                          objectId: UInt16) -> Int32 {
        let now: Date = Date.now

        // We need to make a CMSampleBuffer for this audio packet.
        let block = try! CMBlockBuffer(length: length)
        try! block.replaceDataBytes(with: .init(start: data, count: length))
        let format = try! CMFormatDescription(mediaType: .audio, mediaSubType: .opus)
        let sample = try! CMSampleBuffer(dataBuffer: block,
                                         formatDescription: format,
                                         numSamples: 1,
                                         sampleTimings: [
                                            .init(duration: CMTime(seconds: self.opusWindowSize.rawValue * 1000, preferredTimescale: 1000),
                                                  presentationTimeStamp: CMTime(seconds: now.timeIntervalSince1970, preferredTimescale: 1),
                                                  decodeTimeStamp: .invalid)
                                         ],
                                         sampleSizes: [length])
        try! sample.setSequenceNumber(UInt64(groupId))
        
        // Write to the jitter buffer.
        do {
            try self.jitterBuffer.write(videoFrame: sample)
        } catch {
            Self.logger.error("Failed to write to jitter buffer: \(error.localizedDescription)")
        }
        
        if let measurement = measurement {
            let date: Date? = self.granularMetrics ? now : nil
            Task(priority: .utility) {
                await measurement.receivedBytes(received: UInt(length), timestamp: date)
                await measurement.callbacks(callbacks: self.callbacks.value, timestamp: date)
            }
        }
        return 0
    }
}

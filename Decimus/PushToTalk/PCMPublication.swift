// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import CoreAudio
import Accelerate
import Synchronization

let pcmFormat = AudioStreamBasicDescription(mSampleRate: 8000,
                                            mFormatID: kAudioFormatALaw,
                                            mFormatFlags: 0,
                                            mBytesPerPacket: 1,
                                            mFramesPerPacket: 1,
                                            mBytesPerFrame: 1,
                                            mChannelsPerFrame: 1,
                                            mBitsPerChannel: 8,
                                            mReserved: 0)

class PCMPublication: Publication, AudioPublication {
    private let logger: DecimusLogger
    private let opusWindowSize: OpusWindowSize
    private let engine: DecimusAudioEngine
    private var encodeTask: Task<(), Never>?
    private let pcm: AVAudioPCMBuffer
    private let windowFrames: AVAudioFrameCount
    private let groupId: UInt64
    private var currentObjectId: UInt64 = 0
    private let bootDate: Date
    private let participantId: ParticipantId
    private let publish: Atomic<Bool>
    private let converter: AVAudioConverter
    private let desiredFormat: AVAudioFormat
    private var didOneMorePublish = true
    private var currentRequestId: UInt32?
    private let verbose: Bool

    init(profile: Profile,
         participantId: ParticipantId,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         engine: DecimusAudioEngine,
         config: AudioCodecConfig,
         endpointId: String,
         relayId: String,
         startActive: Bool,
         groupId: UInt64,
         markRequest: Bool,
         verbose: Bool) throws {
        self.engine = engine
        let namespace = profile.namespace.joined()
        let ftn = try FullTrackName(namespace: profile.namespace, name: profile.name!)
        self.logger = .init(PCMPublication.self, prefix: ftn.description)
        self.opusWindowSize = opusWindowSize
        self.currentRequestId = markRequest ? 0 : nil

        // Create a buffer to hold raw data waiting fosr encode.
        let format = DecimusAudioEngine.format
        self.windowFrames = AVAudioFrameCount(format.sampleRate * self.opusWindowSize.rawValue)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: self.windowFrames * 2) else {
            throw "Failed to allocate PCM buffer"
        }
        self.pcm = pcm

        guard let defaultPriority = profile.priorities?.first,
              let defaultTTL = profile.expiry?.first else {
            throw "Missing expected profile values"
        }
        self.bootDate = Date.now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        self.participantId = participantId
        self.publish = .init(startActive)
        self.groupId = groupId
        var asbd = pcmFormat
        guard let desired = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: format, to: desired) else {
            throw "Unsupported conversion"
        }
        self.desiredFormat = desired
        self.converter = converter
        self.verbose = verbose

        try super.init(profile: profile,
                       trackMode: .datagram,
                       defaultPriority: UInt8(clamping: defaultPriority),
                       defaultTTL: UInt16(clamping: defaultTTL),
                       submitter: metricsSubmitter,
                       endpointId: endpointId,
                       relayId: relayId,
                       logger: self.logger)

        // Setup encode job.
        self.encodeTask = .init(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                if let self = self {
                    // Determine what to do.
                    let shouldPublish: Bool
                    let last: Bool
                    if self.publish.load(ordering: .acquiring) {
                        shouldPublish = true
                        last = false
                    } else if !self.didOneMorePublish {
                        shouldPublish = true
                        self.didOneMorePublish = true
                        last = true
                    } else {
                        shouldPublish = false
                        last = false
                    }

                    if shouldPublish {
                        do {
                            let encodedChunks = try self.flushEncode(last: last)
                            if encodedChunks.count > 0 {
                                for index in 0..<encodedChunks.count {
                                    let last = last && index == encodedChunks.count - 1
                                    let data = encodedChunks[index]
                                    self.publish(data: data.encodedData, timestamp: data.timestamp, final: last)
                                }
                            } else if last {
                                self.publish(data: Data(), timestamp: Date.now, final: true)
                            }
                        } catch {
                            self.logger.error("Failed encode: \(error)")
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(opusWindowSize.rawValue),
                                      tolerance: .seconds(opusWindowSize.rawValue / 2),
                                      clock: .continuous)
            }
        }

        self.logger.info("Registered PCM publication for namespace \(namespace)")
    }

    deinit {
        self.encodeTask?.cancel()
        self.logger.debug("Deinit")
    }

    func togglePublishing(active: Bool) {
        self.publish.store(active, ordering: .releasing)
        if !active {
            self.didOneMorePublish = false
        }
    }

    private func publish(data: Data, timestamp: Date, final: Bool) {
        let status = self.getStatus()
        guard status == .ok || status == .subscriptionUpdated else {
            self.logger.warning("Not published due to status: \(status)")
            return
        }
        var priority = self.getPriority(0)
        var ttl = self.getTTL(0)
        let loc = LowOverheadContainer(timestamp: timestamp, sequence: self.currentObjectId)
        let chunk = ChunkMessage(type: self.currentRequestId != nil ? .aiAudio : .audio,
                                 isLastChunk: final,
                                 data: data,
                                 requestId: self.currentRequestId)
        if final,
           let currentRequestId = self.currentRequestId {
            self.currentRequestId = currentRequestId + 1
        }
        var chunkData = Data(capacity: chunk.size)
        chunk.encode(into: &chunkData)
        let published = self.publish(groupId: self.groupId,
                                     objectId: self.currentObjectId,
                                     data: chunkData,
                                     priority: &priority,
                                     ttl: &ttl,
                                     loc: loc)
        switch published {
        case .ok:
            self.currentObjectId += 1
            if self.verbose {
                self.logger.debug("Published object \(self.groupId):\(self.currentObjectId)")
            }
        default:
            self.logger.warning("Failed to publish: \(published)")
        }
    }

    private func publish(groupId: UInt64,
                         objectId: UInt64,
                         data: Data,
                         priority: UnsafePointer<UInt8>?,
                         ttl: UnsafePointer<UInt16>?,
                         loc: LowOverheadContainer) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: groupId,
                                     objectId: objectId,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.publishObject(headers, data: data, extensions: loc.extensions)
    }

    struct EncodeResult {
        let encodedData: Data
        let timestamp: Date
    }

    private func flushEncode(last: Bool) throws -> [EncodeResult] {
        var results: [EncodeResult] = []
        while let encoded = try self.encode(last: false) {
            results.append(encoded)
        }
        if last,
           let oneMore = try self.encode(last: true) {
            results.append(oneMore)
        }
        return results
    }

    private func encode(last: Bool) throws -> EncodeResult? {
        guard let buffer = self.engine.microphoneBuffer else {
            #if os(macOS)
            return nil
            #else
            throw "No Audio Input"
            #endif
        }

        // If there are not enough frames to fill a window we might as well bail.
        if !last {
            let available = buffer.peek()
            guard available.frames >= self.windowFrames else { return nil }
        }

        // Convert this data to ALAW 16KHz 16 bit mono.
        let requiredConvertedSamples = self.opusWindowSize.rawValue * self.desiredFormat.sampleRate
        guard let destination = AVAudioPCMBuffer(pcmFormat: self.desiredFormat,
                                                 frameCapacity: AVAudioFrameCount(requiredConvertedSamples)) else {
            throw "ALaw PCM conversion unsupported"
        }
        var nsError: NSError?
        var timestamp: AudioTimeStamp?
        self.converter.convert(to: destination, error: &nsError) { packets, status in
            let peek = buffer.peek()
            if !last && peek.frames < packets {
                status.pointee = .noDataNow
                return .none
            }

            guard packets < self.pcm.frameCapacity else {
                self.logger.error("PCM conversion asked for too much: \(packets)/\(self.pcm.frameCapacity)")
                status.pointee = .noDataNow
                return nil
            }

            self.pcm.frameLength = packets
            let sourceData = buffer.dequeue(frames: min(peek.frames, packets),
                                            buffer: &self.pcm.mutableAudioBufferList.pointee)
            let silenceFrames = packets - sourceData.frames
            if silenceFrames > 0 {
                // Pad with silence.
                let bytes = DecimusAudioEngine.format.streamDescription.pointee.mBytesPerFrame
                let silenceFramesStart = sourceData.frames * bytes
                let silenceFramesBytes = silenceFrames * bytes
                memset(self.pcm.mutableAudioBufferList.pointee.mBuffers.mData?.advanced(by: Int(silenceFramesStart)),
                       0,
                       Int(silenceFramesBytes))
            }
            timestamp = sourceData.timestamp
            status.pointee = .haveData
            return self.pcm
        }
        if let nsError {
            self.logger.error("ALaw PCM Conversion Failed: \(nsError.localizedDescription)")
        }
        guard destination.frameLength > 0 else {
            return nil
        }
        assert(destination.frameLength == AVAudioFrameCount(self.opusWindowSize.rawValue * self.desiredFormat.sampleRate))

        // Get the data.
        let ptr = destination.audioBufferList.pointee.mBuffers.mData
        let len = destination.audioBufferList.pointee.mBuffers.mDataByteSize
        let data = Data(bytesNoCopy: ptr!, count: Int(len), deallocator: .none)

        // Timestamp.
        guard let timestamp else {
            assert(false)
            return nil
        }
        let wallClock = try getAudioDate(timestamp.mHostTime, bootDate: self.bootDate)

        // Encode this data.
        return .init(encodedData: data, timestamp: wallClock)
    }
}

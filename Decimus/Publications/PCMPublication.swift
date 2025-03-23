// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFAudio
import CoreAudio
import Accelerate
import Synchronization

class PCMPublication: Publication, AudioPublication {
    private let logger = DecimusLogger(PCMPublication.self)
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

    init(profile: Profile,
         participantId: ParticipantId,
         metricsSubmitter: MetricsSubmitter?,
         opusWindowSize: OpusWindowSize,
         engine: DecimusAudioEngine,
         config: AudioCodecConfig,
         endpointId: String,
         relayId: String,
         startActive: Bool,
         groupId: UInt64 = UInt64(Date.now.timeIntervalSince1970)) throws {
        self.engine = engine
        let namespace = profile.namespace.joined()
        self.opusWindowSize = opusWindowSize

        // Create a buffer to hold raw data waiting for encode.
        let format = DecimusAudioEngine.format
        self.windowFrames = AVAudioFrameCount(format.sampleRate * self.opusWindowSize.rawValue)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: self.windowFrames) else {
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
        var asbd = AudioStreamBasicDescription(mSampleRate: 16000,
                                               mFormatID: kAudioFormatALaw,
                                               mFormatFlags: 0,
                                               mBytesPerPacket: 1,
                                               mFramesPerPacket: 1,
                                               mBytesPerFrame: 1,
                                               mChannelsPerFrame: 1,
                                               mBitsPerChannel: 8,
                                               mReserved: 0)
        guard let desired = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: format, to: desired) else {
            throw "Unsupported conversion"
        }
        self.desiredFormat = desired
        self.converter = converter

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
                if let self = self,
                   self.publish.load(ordering: .acquiring) {
                    do {
                        var encodePassCount = 0
                        while let data = try self.encode() {
                            encodePassCount += 1
                            self.publish(data: data.encodedData, timestamp: data.timestamp, decibel: data.decibelLevel)
                        }
                    } catch {
                        self.logger.error("Failed encode: \(error)")
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
    }

    private func publish(data: Data, timestamp: Date, decibel: Int) {
        //        let status = self.getStatus()
        //        guard status == .ok || status == .subscriptionUpdated else {
        //            Self.logger.warning("Not published due to status: \(status)")
        //            return
        //        }
        //        var priority = self.getPriority(0)
        //        var ttl = self.getTTL(0)
        //        let loc = LowOverheadContainer(timestamp: timestamp, sequence: self.currentObjectId)
        //        let adjusted = UInt8(abs(decibel))
        //        let mask: UInt8 = adjusted == Self.silence ? 0b00000000 : 0b10000000
        //        let energyLevelValue = adjusted | mask
        //        loc.add(key: Self.energyLevelKey, value: Data([energyLevelValue]))
        //        var participantId = self.participantId.aggregate
        //        loc.add(key: Self.participantIdKey, value: Data(bytes: &participantId, count: MemoryLayout<UInt32>.size))
        //        let published = self.publish(data: data, priority: &priority, ttl: &ttl, loc: loc)
        //        switch published {
        //        case .ok:
        //            self.currentObjectId += 1
        //        default:
        //            Self.logger.warning("Failed to publish: \(published)")
        //        }
    }

    private func publish(data: Data,
                         priority: UnsafePointer<UInt8>?,
                         ttl: UnsafePointer<UInt16>?,
                         loc: LowOverheadContainer) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: self.groupId,
                                     objectId: self.currentObjectId,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.publishObject(headers, data: data, extensions: loc.extensions)
    }

    struct EncodeResult {
        let encodedData: Data
        let timestamp: Date
        let decibelLevel: Int
    }

    private func encode() throws -> EncodeResult? {
        guard let buffer = self.engine.microphoneBuffer else {
            #if os(macOS)
            return nil
            #else
            throw "No Audio Input"
            #endif
        }

        // Are there enough frames available to fill a window?
        let available = buffer.peek()
        guard available.frames >= self.windowFrames else { return nil }

        // Convert this data to ALAW 16KHz 16 bit mono.
        let requiredConvertedSamples = self.opusWindowSize.rawValue * self.desiredFormat.sampleRate
        guard let destination = AVAudioPCMBuffer(pcmFormat: self.desiredFormat,
                                                 frameCapacity: AVAudioFrameCount(requiredConvertedSamples)) else {
            throw "!?"
        }
        print("Pre conversion size: \(destination.frameLength)")
        var nsErorr: NSError?
        self.converter.convert(to: destination, error: &nsErorr) { packets, status in
            let microphoneAudio = AVAudioPCMBuffer(pcmFormat: DecimusAudioEngine.format,
                                                   frameCapacity: .init(packets))!
            microphoneAudio.frameLength = AVAudioFrameCount(packets)
            let sourceData = buffer.dequeue(frames: packets, buffer: &microphoneAudio.mutableAudioBufferList.pointee)
            guard sourceData.frames == packets else {
                self.logger.warning("Only had \(sourceData.frames)/\(packets)")
                status.pointee = .noDataNow
                return microphoneAudio
            }
            status.pointee = .haveData
            return microphoneAudio
        }
        if let nsErorr {
            self.logger.error("CONVERSION ERROR")
            self.logger.error(nsErorr.localizedDescription)
        }
        self.logger.info("Post conversion we got: \(destination.frameLength)")

        // Get the data.
        let ptr: UnsafeMutableRawPointer? = destination.audioBufferList.pointee.mBuffers.mData
        let len = destination.audioBufferList.pointee.mBuffers.mDataByteSize
        let data = Data(bytesNoCopy: ptr!, count: Int(len), deallocator: .none)

        // Encode this data.
        return .init(encodedData: data, timestamp: Date(), decibelLevel: 0)
    }

    private func getAudioLevel(_ buffer: AVAudioPCMBuffer) throws -> Int {
        guard let data = buffer.floatChannelData else {
            throw "Missing float data"
        }
        let channels = Int(buffer.format.channelCount)
        var rms: Float = 0.0
        for channel in 0..<channels {
            var channelRms: Float = 0.0
            vDSP_rmsqv(data[channel], 1, &channelRms, vDSP_Length(buffer.frameLength))
            rms += abs(channelRms)
        }
        rms /= Float(channels)
        let minAudioLevel: Float = -127
        let maxAudioLevel: Float = 0
        guard rms > 0 else {
            return Int(minAudioLevel)
        }
        var decibel = 20 * log10(rms)
        decibel = min(decibel, maxAudioLevel)
        decibel = max(decibel, minAudioLevel)
        return Int(decibel.rounded())
    }
}

// func getAudioDate(_ hostTime: UInt64, bootDate: Date) throws -> Date {
//    let nano: UInt64
//    #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
//    nano = getAudioDateMac(hostTime)
//    #else
//    nano = try getAudioDateiOS(hostTime)
//    #endif
//    let nanoInterval = TimeInterval(nano) / 1_000_000_000
//    return bootDate.addingTimeInterval(nanoInterval)
// }
//
// #if os(macOS) || (os(iOS) && targetEnvironment(macCatalyst))
// func getAudioDateMac(_ hostTime: UInt64) -> UInt64 {
//    AudioConvertHostTimeToNanos(hostTime)
// }
// #endif
//
// func getAudioDateiOS(_ hostTime: UInt64) throws -> UInt64 {
//    // Get absolute time.
//    var info = mach_timebase_info_data_t()
//    let result = mach_timebase_info(&info)
//    guard result == KERN_SUCCESS else {
//        throw "Failed to get mach time"
//    }
//    let factor = TimeInterval(info.numer) / TimeInterval(info.denom)
//    let nanoseconds = TimeInterval(hostTime) * factor
//    return UInt64(nanoseconds)
// }

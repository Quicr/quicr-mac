// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFAudio

class PCMConverter: AudioDecoder {
    let decodedFormat: AVAudioFormat
    let encodedFormat: AVAudioFormat
    private let logger = DecimusLogger(PCMConverter.self)
    private let converter: AVAudioConverter
    private let outputBuffer: AVAudioPCMBuffer
    private let inputData: CircularBuffer
    private let windowSize: OpusWindowSize

    init(decodedFormat: AVAudioFormat, originalFormat: AVAudioFormat, windowSize: OpusWindowSize) throws {
        self.decodedFormat = decodedFormat
        self.encodedFormat = originalFormat
        self.windowSize = windowSize
        let windowFrames = AVAudioFrameCount(decodedFormat.sampleRate * windowSize.rawValue)
        guard let converter = AVAudioConverter(from: originalFormat, to: decodedFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: decodedFormat,
                                                  frameCapacity: windowFrames) else {
            throw "Unsupported"
        }
        self.converter = converter
        self.outputBuffer = outputBuffer
        self.inputData = try .init(length: 320 * 3, format: originalFormat.streamDescription.pointee)
    }

    func write(data: Data) throws -> AVAudioPCMBuffer {
        try data.withUnsafeBytes { [weak self] bytes in
            guard let self = self else { return }
            var bufferList = AudioBufferList(mNumberBuffers: 1,
                                             mBuffers: .init(mNumberChannels: 1,
                                                             mDataByteSize: UInt32(bytes.count),
                                                             mData: .init(mutating: bytes.baseAddress!)))
            var timestamp = AudioTimeStamp()
            try self.inputData.enqueue(buffer: &bufferList, timestamp: &timestamp, frames: UInt32(bytes.count))
        }

        var nsError: NSError?
        self.converter.convert(to: self.outputBuffer,
                               error: &nsError) { [weak self] packets, status in
            guard let self = self else { return nil }
            let peek = self.inputData.peek()
            guard peek.frames >= packets else {
                // Not enough, try again later.
                status.pointee = .noDataNow
                return .init()
            }
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.encodedFormat, frameCapacity: packets)!
            inputBuffer.frameLength = packets
            let dequeued = self.inputData.dequeue(frames: packets,
                                                  buffer: &inputBuffer.mutableAudioBufferList.pointee)
            guard dequeued.frames == packets else {
                // TODO: what to do here.
                self.logger.error("Peek lied to us")
                return .init()
            }
            inputBuffer.frameLength = packets
            status.pointee = .haveData
            return inputBuffer
        }
        return self.outputBuffer
    }

    func frames(data: Data) throws -> AVAudioFrameCount {
        return AVAudioFrameCount(data.count)
    }

    func plc(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let silence = AVAudioPCMBuffer(pcmFormat: self.decodedFormat, frameCapacity: frames)!
        silence.frameLength = frames
        return silence
    }

    func reset() throws {
        self.converter.reset()
        self.inputData.clear()
        self.outputBuffer.frameLength = 0
    }
}

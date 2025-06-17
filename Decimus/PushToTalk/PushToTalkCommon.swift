// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Chunks can be encoded/decoded to a wire format.
protocol ChunkCodable {
    /// Initialize from wire.
    /// - Parameter from: The binary data to decode
    /// - Throws: Error if the data cannot be decoded
    init(from data: Data) throws

    /// Serialize this chunk to binary data
    func encode() -> Data
}

/// Errors that can occur during binary message parsing
enum MessageParsingError: Error {
    /// Message type not known.
    case invalidMessageType(UInt8)
    /// Not enough data to fill the chunk.
    case insufficientData
    /// Content type not known.
    case invalidContentType(UInt8)
    /// Contained length didn't match available data bytes.
    case dataLengthMismatch
}

/// Types of messages in the protocol
enum MessageType: UInt8 {
    case pttAudio = 1       // PTT Audio
    case aiAudioRequest = 2 // AI audio request
    case aiResponse = 3     // AI Response
    case chat = 4           // Chat message
}

/// Content types for AI responses
enum ContentType: UInt8 {
    case audio = 0
    case json = 1
}

enum Message {
    case audio(AudioChunk)
    case aiAudioRequest(AIRequestChunk)
    case aiResponse(AIResponseChunk)
    case chat(ChatMessage)
}

/// Audio chunk message for PTT audio
struct AudioChunk: ChunkCodable {
    /// Whether this is the last chunk in the sequence
    let isLastChunk: Bool
    /// The audio data bytes
    let audioData: Data

    init(isLastChunk: Bool, audioData: Data) {
        self.isLastChunk = isLastChunk
        self.audioData = audioData
    }

    func encode() -> Data {
        var data = Data()
        data.append(MessageType.pttAudio.rawValue)
        data.append(self.isLastChunk ? UInt8(1) : UInt8(0))
        let chunkLength = UInt32(self.audioData.count).bigEndian
        withUnsafeBytes(of: chunkLength) { data.append(contentsOf: $0) }
        data.append(self.audioData)
        return data
    }

    init(from data: Data) throws {
        guard data.count >= 6 else { throw MessageParsingError.insufficientData }

        let type = data[0]
        guard type == MessageType.pttAudio.rawValue else {
            throw MessageParsingError.invalidMessageType(type)
        }

        self.isLastChunk = data[1] != 0

        let lengthBytes = data[2..<6]
        let chunkLength = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        guard data.count >= 6 + Int(chunkLength) else {
            throw MessageParsingError.dataLengthMismatch
        }

        self.audioData = data[6..<(6 + Int(chunkLength))]
    }
}

/// AI Audio request chunk message
struct AIRequestChunk: ChunkCodable {
    /// The ID of this request, used to match with responses
    let requestID: UInt32
    /// Whether this is the last chunk in the sequence
    let isLastChunk: Bool
    /// The audio data bytes
    let audioData: Data

    init(requestID: UInt32, isLastChunk: Bool, audioData: Data) {
        self.requestID = requestID
        self.isLastChunk = isLastChunk
        self.audioData = audioData
    }

    func encode() -> Data {
        var data = Data()
        data.append(MessageType.aiAudioRequest.rawValue)
        withUnsafeBytes(of: requestID.bigEndian) { data.append(contentsOf: $0) }
        data.append(isLastChunk ? UInt8(1) : UInt8(0))
        let chunkLength = UInt32(audioData.count).bigEndian
        withUnsafeBytes(of: chunkLength) { data.append(contentsOf: $0) }
        data.append(audioData)
        return data
    }

    init(from data: Data) throws {
        guard data.count >= 10 else { throw MessageParsingError.insufficientData }

        let type = data[0]
        guard type == MessageType.aiAudioRequest.rawValue else {
            throw MessageParsingError.invalidMessageType(type)
        }

        self.requestID = data[1..<5].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        self.isLastChunk = data[5] != 0

        let lengthBytes = data[6..<10]
        let chunkLength = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        guard data.count >= 10 + Int(chunkLength) else {
            throw MessageParsingError.dataLengthMismatch
        }

        self.audioData = data[10..<(10 + Int(chunkLength))]
    }
}

/// AI Response chunk message
struct AIResponseChunk: ChunkCodable {
    /// The ID of the request this is responding to
    let requestID: UInt32
    /// The content type of the response data
    let contentType: ContentType
    /// Whether this is the last chunk in the sequence
    let isLastChunk: Bool
    /// The response data
    let responseData: Data

    init(requestID: UInt32, contentType: ContentType, isLastChunk: Bool, responseData: Data) {
        self.requestID = requestID
        self.contentType = contentType
        self.isLastChunk = isLastChunk
        self.responseData = responseData
    }

    func encode() -> Data {
        var data = Data()
        data.append(MessageType.aiResponse.rawValue)
        withUnsafeBytes(of: requestID.bigEndian) { data.append(contentsOf: $0) }
        data.append(contentType.rawValue)
        data.append(isLastChunk ? UInt8(1) : UInt8(0))
        let chunkLength = UInt32(responseData.count).bigEndian
        withUnsafeBytes(of: chunkLength) { data.append(contentsOf: $0) }
        data.append(responseData)
        return data
    }

    init(from data: Data) throws {
        guard data.count >= 11 else { throw MessageParsingError.insufficientData }

        let type = data[0]
        guard type == MessageType.aiResponse.rawValue else {
            throw MessageParsingError.invalidMessageType(type)
        }

        self.requestID = data[1..<5].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        guard let contentTypeValue = ContentType(rawValue: data[5]) else {
            throw MessageParsingError.invalidContentType(data[5])
        }
        self.contentType = contentTypeValue

        self.isLastChunk = data[6] != 0

        let lengthBytes = data[7..<11]
        let chunkLength = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        guard data.count >= 11 + Int(chunkLength) else {
            throw MessageParsingError.dataLengthMismatch
        }

        self.responseData = data[11..<(11 + Int(chunkLength))]
    }
}

/// Chat message
struct ChatMessage: ChunkCodable {
    /// The text content of the chat message
    let text: String

    init(text: String) {
        self.text = text
    }

    func encode() -> Data {
        var data = Data()
        data.append(MessageType.chat.rawValue)

        guard let textData = text.data(using: .utf8) else {
            // Empty message if encoding fails
            let emptyLength = UInt32(0).bigEndian
            withUnsafeBytes(of: emptyLength) { data.append(contentsOf: $0) }
            return data
        }

        let chunkLength = UInt32(textData.count).bigEndian
        withUnsafeBytes(of: chunkLength) { data.append(contentsOf: $0) }
        data.append(textData)
        return data
    }

    init(from data: Data) throws {
        guard data.count >= 5 else { throw MessageParsingError.insufficientData }

        let type = data[0]
        guard type == MessageType.chat.rawValue else {
            throw MessageParsingError.invalidMessageType(type)
        }

        let lengthBytes = data[1..<5]
        let chunkLength = lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        guard data.count >= 5 + Int(chunkLength) else {
            throw MessageParsingError.dataLengthMismatch
        }

        let textData = data[5..<(5 + Int(chunkLength))]
        guard let text = String(data: textData, encoding: .utf8) else {
            self.text = ""
            return
        }
        self.text = text
    }
}

struct ChangeChannelMessage: Decodable {
    let channelName: String

    enum CodingKeys: String, CodingKey {
        case channelName = "channel_name"
    }
}

struct ChunkParser {
    func parse(_ data: Data) throws -> Message {
        guard let type = data.first else {
            throw MessageParsingError.insufficientData
        }
        guard let messageType = MessageType(rawValue: type) else {
            throw MessageParsingError.invalidMessageType(type)
        }
        switch messageType {
        case .pttAudio:
            return .audio(try .init(from: data))
        case .aiAudioRequest:
            return .aiAudioRequest(try .init(from: data))
        case .aiResponse:
            return .aiResponse(try .init(from: data))
        case .chat:
            return .chat(try .init(from: data))
        }
    }
}

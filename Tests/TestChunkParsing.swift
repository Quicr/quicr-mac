// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Testing
@testable import QuicR

private let testJSON = """
    {
        "vectors": {
            "audio": {
                "type": 1,
                "last_chunk": true,
                "chunk_length": 4,
                "chunk_data": "01 02 03 04",
                "vector": "01 01 00 00 00 04 01 02 03 04"
            },
            "ai_request": {
                "type": 2,
                "request_id": 12345,
                "last_chunk": true,
                "chunk_length": 4,
                "chunk_data": "01 02 03 04",
                "vector": "02 00 00 30 39 01 00 00 00 04 01 02 03 04"
            },
            "ai_response_text": {
                "type": 3,
                "request_id": 12345,
                "content_type": 1,
                "last_chunk": true,
                "chunk_length": 4,
                "chunk_data": "01 02 03 04",
                "vector": "03 00 00 30 39 01 01 00 00 00 04 01 02 03 04"
            },
            "ai_response_audio": {
                "type": 3,
                "request_id": 12345,
                "content_type": 0,
                "last_chunk": true,
                "chunk_length": 4,
                "chunk_data": "01 02 03 04",
                "vector": "03 00 00 30 39 00 01 00 00 00 04 01 02 03 04"
            },
            "chat": {
                "type": 4,
                "chunk_length": 11,
                "chunk_data": "68 65 6C 6C 6F 20 77 6F 72 6C 64",
                "vector": "04 00 00 00 0B 68 65 6C 6C 6F 20 77 6F 72 6C 64",
                "message": "hello world"
            }
        }
    }
    """

private struct TestVectors: Decodable {
    let vectors: VectorList
}

private struct VectorList: Decodable {
    let audio: Vector
    let aiRequest: Vector
    let aiResponseAudio: Vector
    let aiResponseText: Vector
    let chat: Vector

    private enum CodingKeys: String, CodingKey {
        case audio
        case aiRequest = "ai_request"
        case aiResponseAudio = "ai_response_audio"
        case aiResponseText = "ai_response_text"
        case chat = "chat"
    }
}

private struct Vector: Decodable {
    let type: Int
    let requestId: UInt32?
    let contentType: UInt8?
    let lastChunk: Bool?
    let chunkLength: Int
    let chunkData: String
    let vector: String
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case type, vector, message
        case requestId = "request_id"
        case contentType = "content_type"
        case lastChunk = "last_chunk"
        case chunkLength = "chunk_length"
        case chunkData = "chunk_data"
    }
}

@Test("Chunk Parsing")
func testChunkParsing() throws {
    let vectors = try JSONDecoder().decode(TestVectors.self, from: .init(testJSON.utf8))
    try testVector(vector: vectors.vectors.audio)
    try testVector(vector: vectors.vectors.aiRequest)
    try testVector(vector: vectors.vectors.aiResponseAudio)
    try testVector(vector: vectors.vectors.aiResponseText)
    try testVector(vector: vectors.vectors.chat)
}

private func testVector(vector: Vector) throws {
    let data = hexToData(vector.vector)
    let parsed = try ChunkParser().parse(data)
    switch parsed {
    case .audio(let audio):
        #expect(vector.type == MessageType.pttAudio.rawValue)
        #expect(audio.isLastChunk == vector.lastChunk)
        #expect(audio.audioData.count == vector.chunkLength)
        #expect(audio.audioData == hexToData(vector.chunkData))
        #expect(audio.encode() == data)
    case .aiAudioRequest(let request):
        #expect(vector.type == MessageType.aiAudioRequest.rawValue)
        #expect(request.requestID == vector.requestId!)
        #expect(request.isLastChunk == vector.lastChunk)
        #expect(request.audioData.count == vector.chunkLength)
        #expect(request.audioData == hexToData(vector.chunkData))
        #expect(request.encode() == data)
    case .aiResponse(let response):
        #expect(vector.type == MessageType.aiResponse.rawValue)
        #expect(response.requestID == vector.requestId!)
        #expect(response.isLastChunk == vector.lastChunk)
        #expect(response.contentType.rawValue == vector.contentType!)
        #expect(response.encode() == data)
    case .chat(let chat):
        #expect(vector.type == MessageType.chat.rawValue)
        #expect(chat.text.count == vector.chunkLength)
        #expect(chat.text == vector.message!)
        #expect(chat.encode() == data)
    }
}

private func hexToData(_ hex: String) -> Data {
    let hex = hex.replacingOccurrences(of: " ", with: "")
    assert(hex.count.isMultiple(of: 2))
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        let byte = hex[index..<next]
        data.append(UInt8(byte, radix: 16)!) // swiftlint:disable:this force_unwrapping
        index = next
    }
    return data
}

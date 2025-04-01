// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

struct EndpointInfo: Decodable {
    let id: UUID
    let owner: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case id, owner
        case language = "lang-preference"
    }
}

struct Track: Decodable {
    let channelName: String
    let language: String?
    let tracknamespace: [String]
    let trackname: String
    let codec: String
    let samplerate: Int?
    let channelConfig: String?
    let bitrate: Int?

    enum CodingKeys: String, CodingKey {
        case channelName = "channel_name"
        case language
        case tracknamespace
        case trackname
        case codec
        case samplerate
        case channelConfig
        case bitrate
    }
}

struct PTTManifest: Decodable {
    let endpointInfo: EndpointInfo
    let publications: [Track]
    let subscriptions: [Track]

    enum CodingKeys: String, CodingKey {
        case endpointInfo = "endpoint_info"
        case publications
        case subscriptions
    }
}

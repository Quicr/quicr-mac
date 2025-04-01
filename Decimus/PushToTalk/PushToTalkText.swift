// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

struct ChannelMessage: Decodable {
    let channel: String
    let ftn: FullTrackName
    let codec: String
    let sampleRate: Int
    let channelConfig: Int
    let bitrate: Int

    enum CodingKeys: String, CodingKey {
        case channel = "channel_name"
        case namespace = "tracknamespace"
        case name = "trackname"
        case codec
        case sampleRate = "samplerate"
        case channelConfig = "channelConfig"
        case bitrate
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.channel = try container.decode(String.self, forKey: .channel)
        let namespace = try container.decode([String].self, forKey: .namespace)
        let name = try container.decode(String.self, forKey: .name)
        self.ftn = try .init(namespace: namespace, name: name)
        self.codec = try container.decode(String.self, forKey: .codec)
        self.sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        self.channelConfig = try container.decode(Int.self, forKey: .channelConfig)
        self.bitrate = try container.decode(Int.self, forKey: .bitrate)
    }
}

class PushToTalkText: Subscription {
    private let logger = DecimusLogger(PushToTalkText.self)

    init(_ ftn: FullTrackName) throws {
        let tuple: [String] = ftn.nameSpace.reduce(into: []) { $0.append(.init(data: $1, encoding: .utf8)!) }
        let profile = Profile(qualityProfile: "",
                              expiry: nil,
                              priorities: nil,
                              namespace: tuple,
                              channel: nil,
                              name: .init(data: ftn.name, encoding: .utf8)!)
        try super.init(profile: profile,
                       endpointId: "",
                       relayId: "",
                       metricsSubmitter: nil,
                       priority: 0,
                       groupOrder: .originalPublisherOrder,
                       filterType: .latestObject) { print($0) }
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        guard let chunk = try? ChunkMessage(from: data) else {
            self.logger.error("Failed to parse chunk")
            return
        }
        guard let channel = try?JSONDecoder().decode(ChannelMessage.self, from: chunk.data) else {
            self.logger.error("Failed to parse chunk JSON")
            return
        }

        self.logger.notice("\(chunk)")
        self.logger.notice("\(channel)")
    }
}

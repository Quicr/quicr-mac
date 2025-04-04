// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Observation

@Observable
class PushToTalkText: Subscription {
    private let logger: DecimusLogger
    var currentChannel: String?

    init(_ ftn: FullTrackName) throws {
        self.logger = DecimusLogger(PushToTalkText.self, prefix: ftn.description)
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
        self.logger.info("Received object: \(objectHeaders.groupId):\(objectHeaders.objectId)")
        guard let chunk = try? ChunkMessage(from: data) else {
            self.logger.error("Failed to parse chunk")
            return
        }
        if let changeChannel = try? JSONDecoder().decode(ChangeChannelMessage.self, from: chunk.data) {
            self.logger.info("Received change channel to: \(changeChannel.channelName)")
            self.currentChannel = changeChannel.channelName
            return
        }

        if let string = String(data: chunk.data, encoding: .utf8) {
            self.logger.info("Received message: \(string)")
            return
        }

        self.logger.notice("Gateway message: \(chunk)")
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Observation

@Observable
class PushToTalkText: Subscription {
    private let logger: DecimusLogger
    private let sframeContext: SFrameContext?
    var currentChannel: String?

    init(_ ftn: FullTrackName, sframeContext: SFrameContext?) throws {
        self.logger = DecimusLogger(PushToTalkText.self, prefix: ftn.description)
        self.sframeContext = sframeContext
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
        let unprotected: Data
        if let sframeContext = self.sframeContext {
            do {
                unprotected = try sframeContext.mutex.withLock { try $0.unprotect(ciphertext: data) }
            } catch {
                self.logger.error("Failed to unprotect data: \(error.localizedDescription)")
                return
            }
        } else {
            unprotected = data
        }

        self.logger.info("Received object: \(objectHeaders.groupId):\(objectHeaders.objectId)")
        guard let chunk = try? ChatMessage(from: unprotected) else {
            self.logger.error("Failed to parse chunk")
            return
        }

        if let changeChannel = try? JSONDecoder().decode(ChangeChannelMessage.self, from: .init(chunk.text.utf8)) {
            self.logger.info("Received change channel to: \(changeChannel.channelName)")
            self.currentChannel = changeChannel.channelName
            return
        }

        self.logger.info("Received message: \(chunk.text)")
    }
}

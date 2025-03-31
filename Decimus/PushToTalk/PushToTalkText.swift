// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

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
        guard let chunk = try? ChunkMessage(from: data) else { print("FAILED TO PARSE"); return }
        self.logger.notice("\(chunk)")
    }
}

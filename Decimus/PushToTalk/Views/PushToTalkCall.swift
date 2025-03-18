// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

private enum Destination {
    case ai // swiftlint:disable:this identifier_name
    case channel
}

struct PushToTalkCall: View {
    private let manager: PushToTalkManager
    private let logger = DecimusLogger(PushToTalkCall.self)
    private let channels: [Destination: UUID]
    @State private var ready = false

    init(manager: PushToTalkManager, aiChannel: UUID, channel: UUID) {
        self.manager = manager
        self.channels = [
            .ai: aiChannel,
            .channel: channel
        ]
    }

    var body: some View {
        ZStack {
            VStack {
                PushToTalkButton("AI",
                                 start: { self.talk(.ai) },
                                 end: { self.stopTalking(.ai) })
                PushToTalkButton("Channel",
                                 start: { self.talk(.channel) },
                                 end: { self.stopTalking(.channel) })
            }
            .padding()
            .disabled(!self.ready)
            if !self.ready {
                ProgressView()
            }
        }

        .task {
            for channel in self.channels {
                do {
                    let channel = PushToTalkChannel(uuid: channel.value,
                                                    sendTo: <#T##FullTrackName#>,
                                                    receiveFrom: <#T##FullTrackName#>,
                                                    publicationFactory: <#T##any PublicationFactory#>,
                                                    subscriptionFactory: <#T##any SubscriptionFactory#>)
                    try await self.manager.registerChannel(.init(uuid: channel.value))
                } catch {
                    self.logger.error("Failed to register channel: \(error.localizedDescription)")
                }
            }
            self.ready = true
        }
    }

    private func talk(_ destination: Destination) {
        do {
            try self.manager.startTransmitting(self.channels[destination]!)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
    }

    private func stopTalking(_ destination: Destination) {
        do {
            try self.manager.stopTransmitting(self.channels[destination]!)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
    }
}

#Preview {
    let manager = MockPushToTalkManager(api: PushToTalkServer(url: .init(string: "http://127.0.0.1:8080")!, name: "hi"))
    PushToTalkCall(manager: manager, aiChannel: UUID(), channel: UUID())
}

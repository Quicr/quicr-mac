// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import CryptoKit

private enum Destination {
    case ai // swiftlint:disable:this identifier_name
    case channel
}

struct PushToTalkCall: View {
    private let manager: PushToTalkManager
    private let logger = DecimusLogger(PushToTalkCall.self)
    private let channels: [Destination: FullTrackName]
    private let pubFactory: PublicationFactory
    private let subFactory: SubscriptionFactory
    private let moqCallController: MoqCallController
    private let engine: DecimusAudioEngine
    @State private var ready = false
    init(manager: PushToTalkManager,
         aiChannel: FullTrackName,
         channel: FullTrackName,
         moqCallController: MoqCallController,
         publicationFactory: PublicationFactory,
         subscriptionFactory: SubscriptionFactory,
         engine: DecimusAudioEngine) {
        self.manager = manager
        self.channels = [
            .ai: aiChannel,
            .channel: channel
        ]
        self.moqCallController = moqCallController
        self.pubFactory = publicationFactory
        self.subFactory = subscriptionFactory
        self.engine = engine
        engine.setMicrophoneCapture(false)
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
                    let channel = try PushToTalkChannel(moq: channel.value,
                                                        publicationFactory: self.pubFactory,
                                                        subscriptionFactory: self.subFactory,
                                                        callController: self.moqCallController)
                    try await self.manager.registerChannel(channel)
                } catch {
                    self.logger.error("Failed to register channel: \(error.localizedDescription)")
                }
            }
            self.ready = true
        }
    }

    private func talk(_ destination: Destination) {
        self.engine.setMicrophoneCapture(true)
        do {
            try self.manager.startTransmitting(self.channels[destination]!.uuid)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
    }

    private func stopTalking(_ destination: Destination) {
        do {
            try self.manager.stopTransmitting(self.channels[destination]!.uuid)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
        self.engine.setMicrophoneCapture(false)
    }
}

extension FullTrackName {
    var uuid: UUID {
        let bytes = Data(self.nameSpace.joined()) + self.name
        let hash = SHA256.hash(data: bytes)
        let uuidBytes: [UInt8] = [UInt8](hash.suffix(16)) // 128 bits.
        let tuple = uuidBytes.withUnsafeBytes { $0.bindMemory(to: uuid_t.self)[0] }
        return UUID(uuid: tuple)
    }
}

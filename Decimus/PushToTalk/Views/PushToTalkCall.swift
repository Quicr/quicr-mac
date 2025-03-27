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
    private let callState: CallState
    @State private var ready = false
    init(manager: PushToTalkManager,
         aiChannel: FullTrackName,
         channel: FullTrackName,
         callState: CallState) {
        assert(aiChannel != channel)
        assert(callState.controller != nil)
        assert(callState.publicationFactory != nil)
        assert(callState.subscriptionFactory != nil)
        assert(callState.engine != nil)
        self.manager = manager
        self.channels = [
            .ai: aiChannel,
            .channel: channel
        ]
        self.callState = callState
        callState.engine!.setMicrophoneCapture(false)
    }

    var body: some View {
        ZStack {
            VStack {
                PushToTalkButton("AI",
                                 start: { await self.talk(.ai) },
                                 end: { await self.stopTalking(.ai) })
                PushToTalkButton("Channel",
                                 start: { await self.talk(.channel) },
                                 end: { await self.stopTalking(.channel) })
                Spacer()
                Button("Leave") {
                    Task {
                        await self.callState.leave()
                        self.callState.onLeave()
                    }
                }
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
                                                        publicationFactory: self.callState.publicationFactory!,
                                                        subscriptionFactory: self.callState.subscriptionFactory!,
                                                        callController: self.callState.controller!)
                    try await self.manager.registerChannel(channel)
                } catch {
                    self.logger.error("Failed to register channel: \(error.localizedDescription)")
                }
            }
            self.ready = true
        }
    }

    private func talk(_ destination: Destination) async {
        do {
            try await self.manager.startTransmitting(self.channels[destination]!.uuid)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
        self.callState.engine!.setMicrophoneCapture(true)
    }

    private func stopTalking(_ destination: Destination) async {
        do {
            try await self.manager.stopTransmitting(self.channels[destination]!.uuid)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
        self.callState.engine!.setMicrophoneCapture(false)
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

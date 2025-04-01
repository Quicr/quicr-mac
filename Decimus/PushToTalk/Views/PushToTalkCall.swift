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
    @State private var textSubscription: PushToTalkText
    private let callState: CallState
    @State private var ready = false
    @State private var availableChannels: [String]
    @State private var selectedChannel: String
    @State private var channels: [Destination: [FullTrackName]]

    private let manifest: PTTManifest
    private let aiPublish: FullTrackName
    private let aiAudioReceive: FullTrackName
    private let aiTextReceive: FullTrackName

    init(manager: PushToTalkManager,
         manifest: PTTManifest,
         callState: CallState) {
        assert(callState.controller != nil)
        assert(callState.publicationFactory != nil)
        assert(callState.subscriptionFactory != nil)
        assert(callState.engine != nil)
        self.manager = manager
        self.manifest = manifest

        // Channels.
        let aiPublishName = "ai_audio"
        let aiAudioReceiveName = "self_ai_audio"
        let aiTextReceiveName = "self_ai_text"
        var aiPublish: FullTrackName?
        var aiAudioReceive: FullTrackName?
        var aiTextReceive: FullTrackName?
        var availableChannels: [String] = []
        // swiftlint:disable force_try
        for publication in manifest.publications {
            guard publication.channelName != aiPublishName else {
                aiPublish = try! FullTrackName(namespace: publication.tracknamespace, name: publication.trackname)
                continue
            }
            availableChannels.append(publication.channelName)
        }
        for subscription in manifest.subscriptions {
            switch subscription.channelName {
            case aiAudioReceiveName:
                aiAudioReceive = try! .init(namespace: subscription.tracknamespace,
                                            name: "\(callState.audioStartingGroup)")
            case aiTextReceiveName:
                aiTextReceive = try! .init(namespace: subscription.tracknamespace,
                                           name: "\(callState.audioStartingGroup)")
            default:
                break
            }
        }
        self.aiPublish = aiPublish!
        self.aiAudioReceive = aiAudioReceive!
        self.aiTextReceive = aiTextReceive!
        self.availableChannels = availableChannels
        self.selectedChannel = availableChannels.first!

        let first = manifest.publications.first!
        let channel = try! FullTrackName(namespace: first.tracknamespace, name: first.trackname)

        self.channels = [
            .ai: [self.aiPublish, self.aiAudioReceive, self.aiTextReceive],
            .channel: [channel]
        ]
        self.callState = callState
        callState.engine!.setMicrophoneCapture(false)
        self.textSubscription = try! PushToTalkText(aiTextReceive!)
        try! callState.controller!.subscribe(self.textSubscription)
        self.textSubscription = textSubscription
        // swiftlint:enable force_try
    }

    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Spacer()
                    LabeledContent("Channel") {
                        Picker("Channel", selection: self.$selectedChannel) {
                            ForEach(self.availableChannels, id: \.self) { channel in
                                Text(channel.capitalized).tag(channel)
                            }
                        }
                        .labelsHidden()
                    }
                }
                PushToTalkButton("AI",
                                 start: { await self.talk(.ai) },
                                 end: { await self.stopTalking(.ai) })
                PushToTalkButton("Channel",
                                 start: { await self.talk(.channel) },
                                 end: { await self.stopTalking(.channel) })
                Spacer()
                Button("Leave", role: .destructive) {
                    Task {
                        await self.callState.leave()
                        self.callState.onLeave()
                    }
                }
                .buttonStyle(.bordered)
                .padding()
            }
            .padding()
            .disabled(!self.ready)
            if !self.ready {
                ProgressView()
            }
        }
        .task {
            do {
                try await self.doChannels()
            } catch {
                self.logger.error(error.localizedDescription)
            }
        }
        .onDisappear {
            self.ready = false
            do {
                try self.manager.shutdown()
            } catch {
                self.logger.error("Failed to shutdown: \(error.localizedDescription)")
            }
        }
        .onChange(of: self.selectedChannel) {
            guard let channel = self.manifest.publications.filter({ $0.channelName == self.selectedChannel }).first,
                  let ftn = try? FullTrackName(namespace: channel.tracknamespace, name: channel.trackname) else {
                self.logger.error("Couldn't get selected channel out of manifest")
                return
            }
            self.channels = [
                .ai: [self.aiPublish, self.aiAudioReceive, self.aiTextReceive],
                .channel: [ftn]
            ]
        }
        .onChange(of: self.channels) {
            Task {
                try await self.doChannels()
            }
        }
        .onChange(of: self.textSubscription.currentChannel) {
            guard let newChannel = self.textSubscription.currentChannel else { return }
            self.selectedChannel = newChannel
            self.textSubscription.currentChannel = nil
        }
    }

    private func doChannels() async throws {
        self.ready = false
        try self.manager.shutdown()
        for channel in self.channels {
            do {
                let subscribe = channel.value.indices.contains(1) ? channel.value[1] : nil
                let pttChannel = try PushToTalkChannel(moq: channel.value.first!,
                                                       subscribe: subscribe,
                                                       publicationFactory: self.callState.publicationFactory!,
                                                       subscriptionFactory: self.callState.subscriptionFactory!,
                                                       callController: self.callState.controller!)
                try await self.manager.registerChannel(pttChannel)
            } catch {
                self.logger.error("Failed to register channel: \(error.localizedDescription)")
            }
        }
        self.ready = true
    }

    private func talk(_ destination: Destination) async {
        do {
            try await self.manager.startTransmitting(self.channels[destination]!.first!.uuid)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
        self.callState.engine!.setMicrophoneCapture(true)
    }

    private func stopTalking(_ destination: Destination) async {
        do {
            try await self.manager.stopTransmitting(self.channels[destination]!.first!.uuid)
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

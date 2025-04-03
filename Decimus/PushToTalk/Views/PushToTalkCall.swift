// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import CryptoKit

struct Channel: Equatable {
    let tracks: [FullTrackName]
    let name: String
}

private enum Destination {
    case ai // swiftlint:disable:this identifier_name
    case channel
}

struct PushToTalkCall: View {
    @State private var manager: PushToTalkManager?
    private let logger = DecimusLogger(PushToTalkCall.self)
    @State private var textSubscription: PushToTalkText
    private let callState: CallState
    @State private var ready = false
    @State private var availableChannels: [String]
    @State private var selectedChannel: String
    @State private var channels: [Destination: Channel]

    private let manifest: PTTManifest
    private let aiPublish: FullTrackName
    private let aiAudioReceive: FullTrackName
    private let aiTextReceive: FullTrackName

    init(manifest: PTTManifest,
         callState: CallState) {
        assert(callState.controller != nil)
        assert(callState.publicationFactory != nil)
        assert(callState.subscriptionFactory != nil)
        assert(callState.engine != nil)
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
        let firstSub = manifest.subscriptions.first!
        if first.channelName != firstSub.channelName {
            self.logger.error("I'm assuming first publication and subscription are for the same channel and they're not. Complain to me or reorder manifest.")
        }
        let channelSub = try! FullTrackName(namespace: firstSub.tracknamespace, name: firstSub.trackname)

        self.channels = [
            .ai: .init(tracks: [self.aiPublish, self.aiAudioReceive, self.aiTextReceive], name: "AI"),
            .channel: .init(tracks: [channel, channelSub], name: first.channelName.capitalized)
        ]
        self.callState = callState
        callState.engine!.setMicrophoneCapture(false)
        self.textSubscription = try! PushToTalkText(aiTextReceive!)
        try! callState.controller!.subscribe(self.textSubscription)
        self.textSubscription = textSubscription
        // swiftlint:enable force_try
    }

    private func makeManager() async throws -> PushToTalkManager {
        let url: URL = .init(string: "http://192.168.1.35:80")!
        let server = PushToTalkServer(url: url, name: "Rich")
        let manager: PushToTalkManager
        #if os(iOS) && !targetEnvironment(macCatalyst)
        manager = PushToTalkManagerImpl(api: server)
        #else
        manager = MockPushToTalkManager(api: server)
        #endif
        try await manager.start { _ in
            // TODO: Get channel from UUID.
            return nil
        }
        return manager
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
                Text("Speaker: \(self.manager?.activeSpeaker ?? "None")")
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
                self.manager = try await self.makeManager()
                try await self.doChannels()
            } catch {
                self.logger.error(error.localizedDescription)
            }
        }
        .onDisappear {
            self.ready = false
            do {
                try self.manager?.shutdown()
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
            guard let subChannel = self.manifest.subscriptions.filter({$0.channelName == self.selectedChannel}).first,
                  let subFtn = try? FullTrackName(namespace: subChannel.tracknamespace, name: subChannel.trackname) else {
                self.logger.error("Couldn't get selected channel out of manifest")
                return
            }
            self.channels = [
                .ai: .init(tracks: [self.aiPublish, self.aiAudioReceive, self.aiTextReceive], name: "AI"),
                .channel: .init(tracks: [ftn, subFtn], name: channel.channelName.capitalized)
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
        try self.manager?.shutdown()
        try await self.manager?.start { _ in nil }

        let channel = self.channels[.channel]!
        do {
            let pttChannel = try PushToTalkChannel(name: channel.name,
                                                   moq: channel.tracks.first!,
                                                   subscribe: channel.tracks[1],
                                                   publicationFactory: self.callState.publicationFactory!,
                                                   subscriptionFactory: self.callState.subscriptionFactory!,
                                                   callController: self.callState.controller!,
                                                   ai: false,
                                                   engine: self.callState.engine!)
            try await self.manager?.registerChannel(pttChannel, native: true)
        } catch {
            self.logger.error("Failed to register normal PTT channel: \(error.localizedDescription)")
        }

        let ai = self.channels[.ai]!
        do {
            let aiChannel = try PushToTalkChannel(name: ai.name,
                                                  moq: ai.tracks.first!,
                                                  subscribe: ai.tracks[1],
                                                  publicationFactory: self.callState.publicationFactory!,
                                                  subscriptionFactory: self.callState.subscriptionFactory!,
                                                  callController: self.callState.controller!,
                                                  ai: true,
                                                  engine: self.callState.engine!)
            try await self.manager?.registerChannel(aiChannel, native: false)
        } catch {
            self.logger.error("Failed to create AI channel: \(error.localizedDescription)")
        }

        self.ready = true
    }

    private func talk(_ destination: Destination) async {
        do {
            try await self.manager?.startTransmitting(self.channels[destination]!.tracks.first!.uuid)
        } catch {
            self.logger.error("Failed to start talking: \(error.localizedDescription)")
        }
    }

    private func stopTalking(_ destination: Destination) async {
        do {
            try await self.manager?.stopTransmitting(self.channels[destination]!.tracks.first!.uuid)
        } catch {
            self.logger.error("Failed to stop talking: \(error.localizedDescription)")
        }
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

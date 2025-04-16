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
    private let availableChannels: [String]
    @State private var selectedChannel: String
    private let audioChannels: [String: PushToTalkChannel]
    private let aiAudioChannel: PushToTalkChannel
    private let manifest: PTTManifest
    @State private var listenToAll = true
    @AppStorage("Native PTT") private var nativePTT: Bool = false

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

        // Get available channels, order matters.
        var availableChannels: [String] = []
        for publication in manifest.publications {
            guard publication.channelName != aiPublishName else { continue }
            guard !availableChannels.contains(publication.channelName) else {
                self.logger.error("Duplicate channel: \(publication.channelName)")
                continue
            }
            availableChannels.append(publication.channelName)
        }
        self.availableChannels = availableChannels

        // swiftlint:disable force_try
        // Create all the regular audio channels upfront.
        let publicationsByName = Dictionary(uniqueKeysWithValues: manifest.publications.map { ($0.channelName, $0) })
        let subscriptionsByName = Dictionary(uniqueKeysWithValues: manifest.subscriptions.map { ($0.channelName, $0) })
        var audioChannels: [String: PushToTalkChannel] = [:]
        var aiPublish: FullTrackName?
        for channel in publicationsByName {
            guard channel.key != aiPublishName else {
                aiPublish = try! FullTrackName(namespace: channel.value.tracknamespace, name: channel.value.trackname)
                continue
            }
            let publicationFtn = try! FullTrackName(namespace: channel.value.tracknamespace,
                                                    name: channel.value.trackname)
            guard let subscription = subscriptionsByName[channel.key] else {
                self.logger.error("Couldn't find subscription for channel \(channel.key)")
                continue
            }
            let subscriptionFtn = try! FullTrackName(namespace: subscription.tracknamespace,
                                                     name: subscription.trackname)
            do {
                let created = try PushToTalkChannel(name: channel.key,
                                                    moq: publicationFtn,
                                                    subscribe: subscriptionFtn,
                                                    callState: callState,
                                                    ai: false,
                                                    engine: callState.engine!)
                audioChannels[channel.key] = created
            } catch {
                self.logger.error("Failed to create channel \(channel.key): \(error.localizedDescription)")
                continue
            }
        }
        self.audioChannels = audioChannels

        // Create the AI channel.
        var aiAudioReceive: FullTrackName?
        var aiTextReceive: FullTrackName?
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
        self.aiAudioChannel = try! PushToTalkChannel(name: "AI",
                                                     moq: aiPublish!,
                                                     subscribe: aiAudioReceive!,
                                                     callState: callState,
                                                     ai: true,
                                                     engine: callState.engine!)

        self.selectedChannel = availableChannels.first!
        self.callState = callState
        callState.engine!.setMicrophoneCapture(false)
        self.textSubscription = try! PushToTalkText(aiTextReceive!)
        try! callState.controller!.subscribe(self.textSubscription)
        // swiftlint:enable force_try
    }

    private func makeManager() async throws -> PushToTalkManager {
        let url: URL = .init(string: "http://192.168.1.35:80")!
        let server = PushToTalkServer(url: url, name: "Rich")
        let manager: PushToTalkManager
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if self.nativePTT {
            manager = PushToTalkManagerImpl(api: server)
        } else {
            manager = PushToTalkManager(api: server)
        }
        #else
        manager = PushToTalkManager(api: server)
        #endif
        try await manager.start()
        return manager
    }

    var body: some View {
        ZStack {
            VStack {

                //                Grid {
                //                    let channels = self.availableChannels.split(2)
                //                    ForEach(channels, id: \.self) { pair in
                //                        GridRow {
                //                            ForEach(pair, id: \.self) { channel in
                //                                let rept
                //                                ChannelBlock(channel: channel)
                //                                    .padding()
                //                            }
                //                        }
                //                    }
                //                }

                HStack {
                    Spacer()
                    Form {
                        LabeledContent("Channel") {
                            Picker("Channel", selection: self.$selectedChannel) {
                                ForEach(self.availableChannels, id: \.self) { channel in
                                    Text(channel.capitalized).tag(channel)
                                }
                            }
                            .labelsHidden()
                        }
                        LabeledToggle("Listen To All", isOn: self.$listenToAll)
                    }.formStyle(.columns)
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
        .onChange(of: self.textSubscription.currentChannel) {
            guard let newChannel = self.textSubscription.currentChannel else { return }
            self.selectedChannel = newChannel
            self.textSubscription.currentChannel = nil
        }
        .onChange(of: self.listenToAll) {
            if self.listenToAll {
                for channel in self.audioChannels {
                    channel.value.startListening()
                }
                return
            }
            for channel in self.audioChannels {
                guard channel.key == self.selectedChannel else {
                    channel.value.stopListening()
                    continue
                }
                channel.value.startListening()
            }
        }
        .onChange(of: self.selectedChannel) { old, new in
            guard !self.listenToAll else { return }
            guard let old = self.audioChannels[old],
                  let new = self.audioChannels[new] else {
                self.logger.error("Failed to find channel")
                return
            }
            old.stopListening()
            new.startListening()
        }
    }

    private func doChannels() async throws {
        self.ready = false
        try self.manager?.shutdown()
        try await self.manager?.start()
        for channel in self.audioChannels {
            try await self.manager?.registerChannel(channel.value, native: true)
        }
        try await self.manager?.registerChannel(self.aiAudioChannel, native: false)
        self.ready = true
    }

    private func talk(_ destination: Destination) async {
        let channel = switch destination {
        case .ai:
            self.aiAudioChannel
        case .channel:
            self.audioChannels[self.selectedChannel]!
        }
        do {
            try await self.manager?.startTransmitting(channel.uuid)
        } catch {
            self.logger.error("Failed to start talking: \(error.localizedDescription)")
        }
    }

    private func stopTalking(_ destination: Destination) async {
        let channel = switch destination {
        case .ai:
            self.aiAudioChannel
        case .channel:
            self.audioChannels[self.selectedChannel]!
        }
        do {
            try await self.manager?.stopTransmitting(channel.uuid)
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

extension Array {
    func split(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

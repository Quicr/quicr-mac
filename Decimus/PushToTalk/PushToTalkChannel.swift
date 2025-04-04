// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import UIKit
import PushToTalk

enum CreatedFrom {
    case request
    case restore
    case mock
}

class PushToTalkChannel {
    let uuid: UUID
    #if os(iOS) && !targetEnvironment(macCatalyst)
    let description: PTChannelDescriptor
    #endif
    private let publication: AudioPublication
    private let subscription: AudioSubscription
    private let callController: MoqCallController
    private let logger: DecimusLogger
    let createdFrom: CreatedFrom
    var joined = false
    static let aiFlagChannel = 9
    let name: String
    private let engine: DecimusAudioEngine

    @MainActor
    init(name: String,
         moq: FullTrackName,
         subscribe: FullTrackName,
         callState: CallState,
         ai: Bool,
         engine: DecimusAudioEngine,
         createdFrom: CreatedFrom = .mock) throws {
        let image = UIImage(systemName: "waveform.circle.fill")
        self.uuid = moq.uuid
        self.name = name
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.description = PTChannelDescriptor(name: name, image: image)
        #endif
        self.callController = callState.controller!
        self.createdFrom = createdFrom
        self.logger = .init(PushToTalkChannel.self, prefix: moq.description)
        self.engine = engine

        func profile(_ namespace: FullTrackName, ai: Bool) -> ProfileSet {
            let tuple: [String] = namespace.nameSpace.reduce(into: []) { $0.append(.init(data: $1, encoding: .utf8)!) }
            let profile = Profile(qualityProfile: "opus,br=24",
                                  expiry: [5000],
                                  priorities: [3],
                                  namespace: tuple,
                                  channel: ai ? Self.aiFlagChannel : nil,
                                  name: String(data: namespace.name, encoding: .utf8)!)
            return .init(type: "simulcast", profiles: [profile])
        }

        // Make the publication.
        let manifestPublication = ManifestPublication(mediaType: "audio",
                                                      sourceName: "source",
                                                      sourceID: self.uuid.uuidString,
                                                      label: self.uuid.uuidString,
                                                      profileSet: profile(moq, ai: ai))
        let created = try self.callController.publish(details: manifestPublication,
                                                      factory: callState.publicationFactory!,
                                                      codecFactory: CodecFactoryImpl())
        assert(created.count == 1)
        guard let audioPublication = created.first?.1 as? AudioPublication else {
            throw "Failed to create audio publication"
        }
        self.publication = audioPublication

        // Make the subscription.
        let manifestSubscription = ManifestSubscription(mediaType: "audio",
                                                        sourceName: self.uuid.uuidString,
                                                        sourceID: self.uuid.uuidString,
                                                        label: self.uuid.uuidString,
                                                        participantId: .init(1),
                                                        profileSet: profile(subscribe, ai: false))
        let set = try self.callController.subscribeToSet(details: manifestSubscription,
                                                         factory: callState.subscriptionFactory!,
                                                         subscribe: true)
        self.subscription = set.getHandlers().first!.value as! AudioSubscription // swiftlint:disable:this force_cast
    }

    func startListening() {
        self.logger.debug("Start listening")
        self.subscription.startListening()
    }

    func stopListening() {
        self.logger.debug("Stop listening")
        self.subscription.stopListening()
    }

    func startTransmitting() {
        self.logger.debug("Start transmitting")
        self.publication.togglePublishing(active: true)
        self.engine.setMicrophoneCapture(true)
    }

    func stopTransmitting() {
        self.logger.debug("Stop transmitting")
        self.publication.togglePublishing(active: false)
        self.engine.setMicrophoneCapture(false)
    }
}

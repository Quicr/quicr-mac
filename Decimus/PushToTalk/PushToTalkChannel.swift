// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import UIKit
import PushToTalk

enum CreatedFrom {
    case request
    case restore
}

class PushToTalkChannel {
    let uuid: UUID
    #if os(iOS) && !targetEnvironment(macCatalyst)
    let description: PTChannelDescriptor
    #endif
    private let publication: AudioPublication
    private let subscription: Subscription
    let createdFrom: CreatedFrom
    var joined = false

    init(uuid: UUID,
         sendTo: FullTrackName,
         receiveFrom: FullTrackName,
         publicationFactory: PublicationFactory,
         subscriptionFactory: SubscriptionFactory,
         createdFrom: CreatedFrom = .request) throws {
        let image = UIImage(systemName: "waveform.circle.fill")
        self.uuid = uuid
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.description = PTChannelDescriptor(name: uuid.uuidString, image: image)
        #endif
        self.createdFrom = createdFrom

        // Make the audio publication.
        func profile(_ namespace: FullTrackName) -> ProfileSet {
            let tuple: [String] = namespace.nameSpace.reduce(into: []) { $0.append(.init(data: $1, encoding: .utf8)!) }
            let profile = Profile(qualityProfile: "opus,br=24", expiry: nil, priorities: nil, namespace: tuple, channel: nil)
            return .init(type: "simulcast", profiles: [profile])
        }

        let manifestPublication = ManifestPublication(mediaType: "audio",
                                                      sourceName: "source",
                                                      sourceID: uuid.uuidString,
                                                      label: uuid.uuidString,
                                                      profileSet: profile(sendTo))
        let createdPublication = try publicationFactory.create(publication: manifestPublication,
                                                               codecFactory: CodecFactoryImpl(),
                                                               endpointId: "endpoint",
                                                               relayId: "relay")
        guard let audioPublication = createdPublication[0].1 as? AudioPublication else {
            throw "Expected Audio Publication"
        }
        self.publication = audioPublication

        let manifestSubscription = ManifestSubscription(mediaType: "audio",
                                                        sourceName: uuid.uuidString,
                                                        sourceID: uuid.uuidString,
                                                        label: uuid.uuidString,
                                                        participantId: .init(1),
                                                        profileSet: profile(receiveFrom))
        self.subscription = try subscriptionFactory.create(subscription: manifestSubscription,
                                                           codecFactory: CodecFactoryImpl(),
                                                           endpointId: "endpoint",
                                                           relayId: "relay").getHandlers().first!.value
    }

    func startTransmitting() {
        self.publication.togglePublishing(active: true)
    }

    func stopTransmitting() {
        self.publication.togglePublishing(active: false)
    }
}

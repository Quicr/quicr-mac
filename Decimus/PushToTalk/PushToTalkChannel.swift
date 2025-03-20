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
    private let callController: MoqCallController
    let createdFrom: CreatedFrom
    var joined = false

    init(moq: FullTrackName,
         publicationFactory: PublicationFactory,
         subscriptionFactory: SubscriptionFactory,
         callController: MoqCallController,
         createdFrom: CreatedFrom = .request) throws {
        let image = UIImage(systemName: "waveform.circle.fill")
        self.uuid = moq.uuid
        #if os(iOS) && !targetEnvironment(macCatalyst)
        self.description = PTChannelDescriptor(name: self.uuid.uuidString, image: image)
        #endif
        self.callController = callController
        self.createdFrom = createdFrom

        func profile(_ namespace: FullTrackName) -> ProfileSet {
            let tuple: [String] = namespace.nameSpace.reduce(into: []) { $0.append(.init(data: $1, encoding: .utf8)!) }
            let profile = Profile(qualityProfile: "opus,br=24",
                                  expiry: [120],
                                  priorities: [1],
                                  namespace: tuple,
                                  channel: nil)
            return .init(type: "simulcast", profiles: [profile])
        }

        // Make the publication.
        let manifestPublication = ManifestPublication(mediaType: "audio",
                                                      sourceName: "source",
                                                      sourceID: self.uuid.uuidString,
                                                      label: self.uuid.uuidString,
                                                      profileSet: profile(moq))
        try self.callController.publish(details: manifestPublication,
                                        factory: publicationFactory,
                                        codecFactory: CodecFactoryImpl())

        guard let audioPublication = self.callController.getPublications().first as? AudioPublication else {
            throw "Failed to create audio publication"
        }
        self.publication = audioPublication

        // Make the subscription.
        let manifestSubscription = ManifestSubscription(mediaType: "audio",
                                                        sourceName: self.uuid.uuidString,
                                                        sourceID: self.uuid.uuidString,
                                                        label: self.uuid.uuidString,
                                                        participantId: .init(1),
                                                        profileSet: profile(moq))
        let set = try self.callController.subscribeToSet(details: manifestSubscription,
                                                         factory: subscriptionFactory,
                                                         subscribe: true)
        self.subscription = set.getHandlers().first!.value
    }

    func startTransmitting() {
        self.publication.togglePublishing(active: true)
    }

    func stopTransmitting() {
        self.publication.togglePublishing(active: false)
    }
}

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
    private let logger: DecimusLogger
    let createdFrom: CreatedFrom
    var joined = false
    static let aiFlagChannel = 9

    init(moq: FullTrackName,
         subscribe: FullTrackName?,
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
        self.logger = .init(PushToTalkCall.self, prefix: moq.description)

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
                                                      profileSet: profile(moq, ai: subscribe != nil))
        let created = try self.callController.publish(details: manifestPublication,
                                                      factory: publicationFactory,
                                                      codecFactory: CodecFactoryImpl())
        assert(created.count == 1)
        guard let audioPublication = created.first?.1 as? AudioPublication else {
            throw "Failed to create audio publication"
        }
        self.publication = audioPublication

        // Make the subscription.
        let subFTN = subscribe ?? moq
        let manifestSubscription = ManifestSubscription(mediaType: "audio",
                                                        sourceName: self.uuid.uuidString,
                                                        sourceID: self.uuid.uuidString,
                                                        label: self.uuid.uuidString,
                                                        participantId: .init(1),
                                                        profileSet: profile(subFTN, ai: false))
        let set = try self.callController.subscribeToSet(details: manifestSubscription,
                                                         factory: subscriptionFactory,
                                                         subscribe: true)
        self.subscription = set.getHandlers().first!.value
    }

    func startTransmitting() {
        self.logger.debug("Start transmitting")
        self.publication.togglePublishing(active: true)
    }

    func stopTransmitting() {
        self.logger.debug("Stop transmitting")
        self.publication.togglePublishing(active: false)
    }
}

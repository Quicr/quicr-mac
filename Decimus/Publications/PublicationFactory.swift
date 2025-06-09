// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFoundation

let noCameraMessage = "No camera capability"
let noAudioError = "No audio capability"

enum PubSubFactoryError: LocalizedError {
    case cannotCreate(String)
}

protocol PublicationFactory {
    func create(publication: ManifestPublication,
                codecFactory: CodecFactory,
                endpointId: String,
                relayId: String) throws -> [(FullTrackName, QPublishTrackHandlerObjC)]
}

class PublicationFactoryImpl: PublicationFactory {
    private let opusWindowSize: OpusWindowSize
    private let reliability: MediaReliability
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine?
    private let metricsSubmitter: MetricsSubmitter?
    private let captureManager: CaptureManager?
    private let participantId: ParticipantId
    private let keyFrameInterval: TimeInterval
    private let stagger: Bool
    private let logger = DecimusLogger(PublicationFactory.self)
    private let verbose: Bool
    private let keyFrameOnUpdate: Bool
    private let startingGroup: UInt64?
    private let sframeContext: SendSFrameContext?

    init(opusWindowSize: OpusWindowSize,
         reliability: MediaReliability,
         engine: DecimusAudioEngine?,
         metricsSubmitter: MetricsSubmitter?,
         granularMetrics: Bool,
         captureManager: CaptureManager?,
         participantId: ParticipantId,
         keyFrameInterval: TimeInterval,
         stagger: Bool,
         verbose: Bool,
         keyFrameOnUpdate: Bool,
         startingGroup: UInt64?,
         sframeContext: SendSFrameContext?) {
        self.opusWindowSize = opusWindowSize
        self.reliability = reliability
        self.engine = engine
        self.metricsSubmitter = metricsSubmitter
        self.granularMetrics = granularMetrics
        self.captureManager = captureManager
        self.participantId = participantId
        self.keyFrameInterval = keyFrameInterval
        self.stagger = stagger
        self.verbose = verbose
        self.keyFrameOnUpdate = keyFrameOnUpdate
        self.startingGroup = startingGroup
        self.sframeContext = sframeContext
    }

    func create(publication: ManifestPublication,
                codecFactory: CodecFactory,
                endpointId: String,
                relayId: String) throws -> [(FullTrackName, QPublishTrackHandlerObjC)] {
        var publications: [(FullTrackName, QPublishTrackHandlerObjC)] = []
        for profile in publication.profileSet.profiles {
            let config = codecFactory.makeCodecConfig(from: profile.qualityProfile, bitrateType: .average)
            let fullTrackName = try profile.getFullTrackName()
            do {
                let publication = try self.create(profile,
                                                  sourceID: publication.sourceID,
                                                  config: config,
                                                  metricsSubmitter: self.metricsSubmitter,
                                                  endpointId: endpointId,
                                                  relayId: relayId)
                publications.append((fullTrackName, publication))
            } catch {
                self.logger.warning("[\(fullTrackName)] Couldn't create publication: \(error.localizedDescription)", alert: true)
            }
        }
        return publications
    }

    func create(_ profile: Profile,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter?,
                endpointId: String,
                relayId: String) throws -> QPublishTrackHandlerObjC {
        switch config.codec {
        case .h264, .hevc:
            guard let captureManager = self.captureManager else {
                throw PubSubFactoryError.cannotCreate(noCameraMessage)
            }
            guard let config = config as? VideoCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            // TODO: SourceID from manifest is bogus, do this for now to retrieve valid device
            let device: AVCaptureDevice
            #if os(macOS)
            device = AVCaptureDevice.default(.external, for: .video, position: .unspecified)!
            #elseif os(tvOS) && targetEnvironment(simulator)
            throw H264PublicationError.noCamera(sourceID)
            #else
            if #available(iOS 17.0, tvOS 17.0, macOS 13.0, *) {
                guard let preferred = AVCaptureDevice.systemPreferredCamera else {
                    throw H264PublicationError.noCamera(sourceID)
                }
                device = preferred
            } else {
                guard let preferred = AVCaptureDevice.default(for: .video) else {
                    throw H264PublicationError.noCamera(sourceID)
                }
                device = preferred
            }
            #endif
            let encoder = try VTEncoder(config: config,
                                        verticalMirror: device.position == .front,
                                        emitStartCodes: false,
                                        keyFrameInterval: self.keyFrameInterval)

            let publication = try H264Publication(profile: profile,
                                                  config: config,
                                                  metricsSubmitter: metricsSubmitter,
                                                  reliable: reliability.video.publication,
                                                  granularMetrics: self.granularMetrics,
                                                  encoder: encoder,
                                                  device: device,
                                                  endpointId: endpointId,
                                                  relayId: relayId,
                                                  stagger: self.stagger,
                                                  verbose: self.verbose,
                                                  keyFrameOnUpdate: self.keyFrameOnUpdate,
                                                  sframeContext: self.sframeContext)
            try captureManager.addInput(publication)
            return publication
        case .opus:
            guard let engine = self.engine else {
                throw PubSubFactoryError.cannotCreate(noAudioError)
            }
            guard let config = config as? AudioCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            return try OpusPublication(profile: profile,
                                       participantId: self.participantId,
                                       metricsSubmitter: metricsSubmitter,
                                       opusWindowSize: opusWindowSize,
                                       reliable: reliability.audio.publication,
                                       engine: engine,
                                       granularMetrics: self.granularMetrics,
                                       config: config,
                                       endpointId: endpointId,
                                       relayId: relayId,
                                       startActive: true,
                                       incrementing: .group,
                                       sframeContext: self.sframeContext)
        case .text:
            return try TextPublication(participantId: self.participantId,
                                       incrementing: .object,
                                       profile: profile,
                                       trackMode: .streamPerGroup,
                                       submitter: metricsSubmitter,
                                       endpointId: endpointId,
                                       relayId: relayId,
                                       sframeContext: self.sframeContext)
        default:
            throw CodecError.noCodecFound(config.codec)
        }
    }
}

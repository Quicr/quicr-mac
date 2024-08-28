import Foundation
import AVFoundation

class PublicationFactory {
    private let opusWindowSize: OpusWindowSize
    private let reliability: MediaReliability
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine

    init(opusWindowSize: OpusWindowSize,
         reliability: MediaReliability,
         engine: DecimusAudioEngine,
         granularMetrics: Bool) {
        self.opusWindowSize = opusWindowSize
        self.reliability = reliability
        self.engine = engine
        self.granularMetrics = granularMetrics
    }

    func create(publication: ManifestPublication) throws -> [(QuicrNamespace, QPublishTrackHandlerObjC)] {
        var publications: [(QuicrNamespace, QPublishTrackHandlerObjC)] = []
        for profile in publication.profileSet.profiles {
            let config = CodecFactory.makeCodecConfig(from: profile.qualityProfile, bitrateType: .average)
            publications.append(try self.create(profile.namespace,
                                                sourceID: publication.sourceID,
                                                config: config,
                                                metricsSubmitter: nil))
        }
        return publications
    }

    func create(_ namespace: QuicrNamespace,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter?) throws -> (QuicrNamespace, QPublishTrackHandlerObjC) {

        switch config.codec {
        case .h264, .hevc:
            guard let config = config as? VideoCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            // TODO: SourceID from manifest is bogus, do this for now to retrieve valid device
            let device: AVCaptureDevice
            if #available(iOS 17.0, tvOS 17.0, *) {
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
            let encoder = try VTEncoder(config: config,
                                        verticalMirror: device.position == .front,
                                        emitStartCodes: config.codec == .hevc)
            let handler = try H264Publication(namespace: namespace,
                                              sourceID: sourceID,
                                              config: config,
                                              metricsSubmitter: metricsSubmitter,
                                              reliable: reliability.video.publication,
                                              granularMetrics: self.granularMetrics,
                                              encoder: encoder,
                                              device: device)
            return (namespace, handler)
        case .opus:
            guard let config = config as? AudioCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            let handler = try OpusPublication(namespace: namespace,
                                              sourceID: sourceID,
                                              metricsSubmitter: metricsSubmitter,
                                              opusWindowSize: opusWindowSize,
                                              reliable: reliability.audio.publication,
                                              engine: self.engine,
                                              granularMetrics: self.granularMetrics,
                                              config: config)
            return (namespace, handler)
        default:
            throw CodecError.noCodecFound(config.codec)
        }
    }
}

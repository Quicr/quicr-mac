import Foundation
import AVFoundation

class PublicationFactory {
    private let opusWindowSize: OpusWindowSize
    private let reliability: MediaReliability
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine
    private let metricsSubmitter: MetricsSubmitter?

    init(opusWindowSize: OpusWindowSize,
         reliability: MediaReliability,
         engine: DecimusAudioEngine,
         metricsSubmitter: MetricsSubmitter?,
         granularMetrics: Bool) {
        self.opusWindowSize = opusWindowSize
        self.reliability = reliability
        self.engine = engine
        self.metricsSubmitter = metricsSubmitter
        self.granularMetrics = granularMetrics
    }

    func create(publication: ManifestPublication) throws -> [(FullTrackName, QPublishTrackHandlerObjC)] {
        var publications: [(FullTrackName, QPublishTrackHandlerObjC)] = []
        for profile in publication.profileSet.profiles {
            let config = CodecFactory.makeCodecConfig(from: profile.qualityProfile, bitrateType: .average)
            let fullTrackName = try FullTrackName(namespace: profile.namespace, name: "")
            let publication = try self.create(fullTrackName,
                                              sourceID: publication.sourceID,
                                              config: config,
                                              metricsSubmitter: self.metricsSubmitter)
            publications.append((fullTrackName, publication))
        }
        return publications
    }

    func create(_ fullTrackName: FullTrackName,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter?) throws -> QPublishTrackHandlerObjC {
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
            return try H264Publication(fullTrackName: fullTrackName,
                                       config: config,
                                       metricsSubmitter: metricsSubmitter,
                                       reliable: reliability.video.publication,
                                       granularMetrics: self.granularMetrics,
                                       encoder: encoder,
                                       device: device)
        case .opus:
            guard let config = config as? AudioCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            return try OpusPublication(fullTrackName: fullTrackName,
                                       metricsSubmitter: metricsSubmitter,
                                       opusWindowSize: opusWindowSize,
                                       reliable: reliability.audio.publication,
                                       engine: self.engine,
                                       granularMetrics: self.granularMetrics,
                                       config: config)
        default:
            throw CodecError.noCodecFound(config.codec)
        }
    }
}

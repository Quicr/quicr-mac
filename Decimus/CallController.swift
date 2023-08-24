import CoreMedia
import AVFoundation
import os

enum CallError: Error {
    case failedToConnect(Int32)
}

class MutableWrapper<T> {
    var value: T
    init(value: T) {
        self.value = value
    }
}

class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {
    private let engine: AVAudioEngine
    private var blocks: MutableWrapper<[AVAudioSinkNodeReceiverBlock]> = .init(value: [])
    private static let logger = DecimusLogger(CallController.self)
    private static let opusSampleRates: [Double] = [.opus8khz, .opus12khz, .opus16khz, .opus24khz, .opus48khz]

    init(metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         config: SubscriptionConfig) {
        do {
            try AVAudioSession.configureForDecimus()
        } catch {
            Self.logger.error("Failed to set configure AVAudioSession: \(error.localizedDescription)")
        }
        engine = .init()
        if engine.outputNode.isVoiceProcessingEnabled != config.voiceProcessing {
            do {
                try engine.outputNode.setVoiceProcessingEnabled(config.voiceProcessing)
            } catch {
                Self.logger.error("Failed to set voice processing: \(error.localizedDescription)")
            }
        }
        assert(engine.outputNode.isVoiceProcessingEnabled == engine.inputNode.isVoiceProcessingEnabled)

        // If voice processing is on, we want to override the format to something usable.
        var desiredFormat: AVAudioFormat?
        let current = AVAudioSession.sharedInstance().sampleRate
        let desiredSampleRate = Self.opusSampleRates.contains(current) ? current : .opus48khz
        if engine.outputNode.isVoiceProcessingEnabled {
            desiredFormat = .init(commonFormat: engine.inputNode.outputFormat(forBus: 0).commonFormat,
                                  sampleRate: desiredSampleRate,
                                  channels: 1,
                                  interleaved: true)!
        }

        // Capture microphone audio.
        let sink: AVAudioSinkNode = .init { [blocks] timestamp, frames, data in
            var success = true
            for block in blocks.value {
                success = success && block(timestamp, frames, data) == .zero
            }
            return success ? .zero : 1
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: desiredFormat)

        super.init()
        self.subscriberDelegate = SubscriberDelegate(submitter: metricsSubmitter,
                                                     config: config,
                                                     engine: engine)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager,
                                                   opusWindowSize: config.opusWindowSize,
                                                   reliability: config.mediaReliability,
                                                   blocks: blocks,
                                                   format: desiredFormat ?? engine.inputNode.outputFormat(forBus: 0))
    }

    func connect(config: CallConfig) async throws {
        let error = super.connect(config.address, port: config.port, protocol: config.connectionProtocol.rawValue)
        guard error == .zero else {
            throw CallError.failedToConnect(error)
        }

        let manifest = try await ManifestController.shared.getManifest(confId: config.conferenceID, email: config.email)
        super.updateManifest(manifest)
        assert(!engine.isRunning)
        try engine.start()
    }

    func disconnect() throws {
        engine.stop()
        super.close()
    }
}

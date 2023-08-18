import CoreMedia
import AVFoundation

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
    let notifier: NotificationCenter = .default
    private let engine: AVAudioEngine
    private var blocks: MutableWrapper<[AVAudioSinkNodeReceiverBlock]> = .init(value: [])

    init(errorWriter: ErrorWriter,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager,
         config: SubscriptionConfig) {
        do {
            try AVAudioSession.configureForDecimus()
        } catch {
            errorWriter.writeError("Failed to set configure AVAudioSession: \(error.localizedDescription)")
        }
        engine = .init()
        if engine.outputNode.isVoiceProcessingEnabled != config.voiceProcessing {
            do {
                try engine.outputNode.setVoiceProcessingEnabled(config.voiceProcessing)
            } catch {
                errorWriter.writeError("Failed to set voice processing: \(error.localizedDescription)")
            }
        }
        assert(engine.outputNode.isVoiceProcessingEnabled == engine.inputNode.isVoiceProcessingEnabled)

        // If voice processing is on, we want to override the format to something usable.
        let desiredFormat: AVAudioFormat?
        var desiredSampleRate = AVAudioSession.sharedInstance().sampleRate
        if desiredSampleRate != .opus48khz &&
            desiredSampleRate != .opus24khz &&
            desiredSampleRate != .opus16khz &&
            desiredSampleRate != .opus12khz &&
            desiredSampleRate != .opus8khz {
            desiredSampleRate = .opus48khz
        }
        if engine.outputNode.isVoiceProcessingEnabled {
            desiredFormat = .init(commonFormat: engine.inputNode.outputFormat(forBus: 0).commonFormat,
                                  sampleRate: desiredSampleRate,
                                  channels: 1,
                                  interleaved: true)!
        } else {
            desiredFormat = nil
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
        self.subscriberDelegate = SubscriberDelegate(errorWriter: errorWriter,
                                                     submitter: metricsSubmitter,
                                                     config: config,
                                                     engine: engine)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager,
                                                   errorWriter: errorWriter,
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

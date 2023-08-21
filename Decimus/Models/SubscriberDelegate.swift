import AVFoundation
import Foundation
import os

class SubscriberDelegate: QSubscriberDelegateObjC {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: SubscriberDelegate.self)
    )

    let participants: VideoParticipants
    private let player: FasterAVEngineAudioPlayer
    private var checkStaleVideoTimer: Timer?
    private let submitter: MetricsSubmitter?
    private let factory: SubscriptionFactory

    init(submitter: MetricsSubmitter?, config: SubscriptionConfig) {
        self.participants = .init()
        do {
            try AVAudioSession.configureForDecimus(targetBufferTime: config.opusWindowSize)
        } catch {
            ObservableError.shared.write(logger: Self.logger, "Failed to set configure AVAudioSession: \(error.localizedDescription)")
        }
        self.player = .init(voiceProcessing: config.voiceProcessing)
        self.submitter = submitter
        self.factory = .init(participants: self.participants, player: self.player, config: config)

        self.checkStaleVideoTimer = .scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let staleVideos = self.participants.participants.filter { _, participant in
                return participant.lastUpdated.advanced(by: DispatchTimeInterval.seconds(2)) < .now()
            }
            for id in staleVideos.keys {
                do {
                    try self.participants.removeParticipant(identifier: id)
                } catch {
                    self.player.removePlayer(identifier: id)
                }
            }
        }
    }

    deinit {
        checkStaleVideoTimer!.invalidate()
    }

    func allocateSub(byNamespace quicrNamepace: QuicrNamespace!,
                     qualityProfile: String!) -> QSubscriptionDelegateObjC? {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile!)
        do {
            return try factory.create(quicrNamepace!,
                                      config: config,
                                      metricsSubmitter: submitter)
        } catch {
            ObservableError.shared.write(logger: Self.logger, "[SubscriberDelegate] Failed to allocate subscription: \(error)")
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: QuicrNamespace!) -> Int32 {
        return 0
    }
}

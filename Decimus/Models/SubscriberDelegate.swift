import AVFoundation
import Foundation

class SubscriberDelegate: QSubscriberDelegateObjC {
    let participants: VideoParticipants
    private let player: FasterAVEngineAudioPlayer
    private let codecFactory: DecoderFactory
    private var checkStaleVideoTimer: Timer?

    init(errorWriter: ErrorWriter, audioFormat: AVAudioFormat?) {
        self.participants = .init()
        self.player = .init(errorWriter: errorWriter)
        self.codecFactory = .init(audioFormat: audioFormat ?? player.inputFormat)

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

    func allocateSub(byNamespace quicrNamepace: String!) -> Any! {
        return Subscription(namespace: quicrNamepace!,
                            codecFactory: codecFactory,
                            participants: participants,
                            player: player)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
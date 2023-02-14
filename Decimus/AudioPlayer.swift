import AVFoundation

/// Plays audio samples out.
/// Single stream right now.
class AudioPlayer {
    private let synchronizer: AVSampleBufferRenderSynchronizer = .init()
    private let renderer: AVSampleBufferAudioRenderer = .init()
    private let engine: AVAudioEngine = .init()
    private let player: AVAudioPlayerNode = .init()

    /// Create a new `AudioPlayer`
    init() {
        // Use AVSampleBufferAudioRenderer for sample playout.
        synchronizer.addRenderer(renderer)

        // Use AVAudioPlayerNode for PCM playout.
        _ = engine.mainMixerNode
        do {
            try engine.start()
        } catch {
            fatalError()
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: OpusSettings.targetFormat)
        player.play()
    }

    /// Write a sample to be played out.
    /// - Parameter sample The audio sample to play.
    func write(sample: CMSampleBuffer) {
        switch renderer.status {
        case .failed:
            fatalError(renderer.error!.localizedDescription)
        case .rendering:
            break
        case .unknown:
            print("UNKNOWN")
        default:
            fatalError()
        }
        self.renderer.enqueue(sample)
        if self.synchronizer.rate == 0 {
            self.synchronizer.setRate(1, time: sample.presentationTimeStamp)
        }
    }

    func write(buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer)
    }
}

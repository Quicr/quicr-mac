import AVFoundation

/// Plays audio samples out.
/// Single stream right now.
class AudioPlayer {
    private let synchronizer: AVSampleBufferRenderSynchronizer = .init()
    private let renderer: AVSampleBufferAudioRenderer = .init()
    
    /// Create a new `AudioPlayer`
    init() {
        synchronizer.addRenderer(renderer)
    }
    
    /// Write a sample to be played out.
    /// - Parameter sample The audio sample to play.
    func write(sample: CMSampleBuffer) {
        self.renderer.enqueue(sample)
        if self.synchronizer.rate == 0 {
            self.synchronizer.setRate(1, time: sample.presentationTimeStamp)
        }
    }
}

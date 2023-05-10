import AVFAudio

/// Represents the ability to mix and play multiple streams of audio.
protocol AudioPlayer {
    /// Write some audio to be played.
    /// - Parameter identifier: The unique identifier for this stream.
    /// - Parameter buffer: The buffer of audio data.
    func write(identifier: UInt64, buffer: AVAudioPCMBuffer)

    /// Remove a stream from the player.
    /// - Parameter identifier: Identifier of the stream to remove.
    func removePlayer(identifier: UInt64)
}

import AVFAudio

/// Represents the ability to mix and play multiple streams of audio.
protocol AudioPlayer {

    /// The format that the player desires input in.
    /// This may not be a requirement depending on the implementation,
    /// but it may be optimal to provide audio in the desired format where possible.
    var inputFormat: AVAudioFormat { get }

    /// Write some audio to be played.
    /// - Parameter identifier: The unique identifier for this stream.
    /// - Parameter buffer: The buffer of audio data.
    func write(identifier: UInt64, buffer: AVAudioPCMBuffer)

    /// Add a player element for the given stream.
    /// - Parameter identifier: The unique identifier for this stream.
    /// - Parameter format: The expected format audio for this stream will arrive in.
    func addPlayer(identifier: UInt64, format: AVAudioFormat)

    /// Remove a stream from the player.
    /// - Parameter identifier: Identifier of the stream to remove.
    func removePlayer(identifier: UInt64)
}

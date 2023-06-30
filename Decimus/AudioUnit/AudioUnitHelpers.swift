import AVFoundation

extension AVAudioSession {

    private static var configuredForDecimus: Bool = false

    /// Helper to configure the AVAudioSession for Decimus.
    static func configureForDecimus() throws {
        guard !configuredForDecimus else { return }
        let audioSession = Self.sharedInstance()
        let options: AVAudioSession.CategoryOptions = []
        #if !os(tvOS)
        options = [.defaultToSpeaker, .allowBluetooth]
        #endif
        try audioSession.setCategory(.playAndRecord,
                                     mode: .videoChat,
                                     options: options)
        try audioSession.setActive(true)
        configuredForDecimus = true
        print("Configured")
    }
}

enum AudioUnitError: Error {
    case IOUnitNull
}

extension AudioStreamBasicDescription: Equatable {
    public static func == (lhs: AudioStreamBasicDescription, rhs: AudioStreamBasicDescription) -> Bool {
        var mutableLhs = lhs
        var mutableRhs = rhs
        return memcmp(&mutableLhs, &mutableRhs, MemoryLayout<Self>.size) == 0
    }
}

extension OSStatus: Error { }

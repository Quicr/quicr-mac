import AVFoundation

extension AVAudioSession {

    private static var configuredForDecimus: Bool = false

    /// Helper to configure the AVAudioSession for Decimus.
    static func configureForDecimus() throws {
        guard !configuredForDecimus else { return }
        let audioSession = Self.sharedInstance()
        try audioSession.setCategory(.playAndRecord,
                                     mode: .videoChat,
                                     options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)
        configuredForDecimus = true
        print("Configured")
    }
}

class AudioUnitFactory {
    private static var ioUnit: AudioUnit?

    /// Create a remote IO audio unit.
    /// - Parameter voip: True to use the voice processing unit, false for raw remote IO.
    /// - Returns The created AudioUnit.
    func makeIOUnit(voip: Bool) throws -> AudioUnit {
        guard Self.ioUnit == nil else {
            fatalError("App can only have one")
        }

        try AVAudioSession.configureForDecimus()

        // Create the unit.
        var auDescription: AudioComponentDescription = .init(
            componentType: kAudioUnitType_Output,
            componentSubType: voip ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        var audioUnit: AudioUnit?
        let component = AudioComponentFindNext(nil, &auDescription)
        let status = AudioComponentInstanceNew(component!, &audioUnit)
        guard status == .zero else {
            fatalError("Failed to create AudioUnit: \(status)")
        }
        Self.ioUnit = audioUnit!
        return audioUnit!
    }

    func clearIOUnit() throws {
        guard Self.ioUnit != nil else {
            fatalError("No io unit made")
        }
        try Self.ioUnit!.stopAndTeardown()
        Self.ioUnit = nil
    }
}

extension AudioUnit {
    /// Attempt to initialize and immediatly start this audio unit.
    func initializeAndStart() throws {
        let initialize = AudioUnitInitialize(self)
        guard initialize == .zero else {
            throw initialize
        }

        let start = AudioOutputUnitStart(self)
        guard start == .zero else {
            throw start
        }
    }

    /// Attempt to stop and teardown this audio unit.
    func stopAndTeardown() throws {
        let stop = AudioOutputUnitStop(self)
        guard stop == .zero else {
            throw stop
        }
        let teardown = AudioComponentInstanceDispose(self)
        guard teardown == .zero else {
            throw teardown
        }
    }

    /// Attempt to set the desired format to the application controllable format of the audio unit.
    /// For a microphone, this is the output side of the input bus.
    /// For a speaker, this is the input side of the output bus.
    /// - Parameter desired: The desired format.
    /// - Parameter microphone: True is this the microphone side per the above, false if speaker.
    /// - Returns The format in use after the attempt to configure. Your desired format MAY NOT have been applied.
    func setFormat(desired: AudioStreamBasicDescription, microphone: Bool) throws -> AudioStreamBasicDescription {
        // Set the microphone output / speaker input.
        var mutableDesiredFormat = desired
        let setFormat = AudioUnitSetProperty(self,
                                             kAudioUnitProperty_StreamFormat,
                                             microphone ? kAudioUnitScope_Output : kAudioUnitScope_Input,
                                             microphone ? 1 : 0,
                                             &mutableDesiredFormat,
                                             UInt32(MemoryLayout.size(ofValue: mutableDesiredFormat)))
        guard setFormat == .zero else {
            throw setFormat
        }

        // This is the actual format being output/requested for input.
        var retrievedActualFormat: AudioStreamBasicDescription = .init()
        var retrievedActualFormatSize: UInt32 = UInt32(MemoryLayout.size(ofValue: retrievedActualFormat))
        let getFormat = AudioUnitGetProperty(self,
                                             kAudioUnitProperty_StreamFormat,
                                             microphone ? kAudioUnitScope_Output : kAudioUnitScope_Input,
                                             microphone ? 1 : 0,
                                             &retrievedActualFormat,
                                             &retrievedActualFormatSize)
        guard getFormat == .zero else {
            throw getFormat
        }

        return retrievedActualFormat
    }
}

extension AudioStreamBasicDescription: Equatable {
    public static func == (lhs: AudioStreamBasicDescription, rhs: AudioStreamBasicDescription) -> Bool {
        var mutableLhs = lhs
        var mutableRhs = rhs
        return memcmp(&mutableLhs, &mutableRhs, MemoryLayout<Self>.size) == 0
    }
}

extension OSStatus: Error { }

import AVFoundation

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

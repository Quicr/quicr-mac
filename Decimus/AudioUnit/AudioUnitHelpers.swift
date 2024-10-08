// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

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
        try audioSession.setPreferredSampleRate(.opus48khz)
        try audioSession.setActive(true)
        try audioSession.setPreferredOutputNumberOfChannels(min(2, audioSession.maximumOutputNumberOfChannels))
        try audioSession.setPreferredInputNumberOfChannels(min(1, audioSession.maximumInputNumberOfChannels))
        configuredForDecimus = true
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

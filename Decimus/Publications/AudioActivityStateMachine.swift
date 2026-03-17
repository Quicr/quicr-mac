// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Values for the AudioActivityIndicator extension header.
enum AudioActivityValue: UInt8, Comparable {
    static func < (lhs: AudioActivityValue, rhs: AudioActivityValue) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    case speechEnd = 0
    case speechStart = 1
    case continuousSpeech = 2
}

/// State machine for voice activity / active speaker.
///
/// Every call to `update` returns a value to include on the object.
/// Transitions are rate-limited by per-transition thresholds.
class AudioActivityStateMachine {
    private let speechStartInterval: TimeInterval
    private let continuousSpeechInterval: TimeInterval

    init(speechStartInterval: TimeInterval, continuousSpeechInterval: TimeInterval) {
        self.speechStartInterval = speechStartInterval
        self.continuousSpeechInterval = continuousSpeechInterval
    }

    private var currentValue: AudioActivityValue = .speechEnd
    private var lastChangeTime: Date?

    /// Process a VAD sample and return the value to send on this object.
    func update(voiceActive: Bool, now: Date) -> AudioActivityValue {
        let desired: AudioActivityValue
        switch (voiceActive, self.currentValue) {
        case (true, .speechEnd):
            desired = .speechStart
        case (true, _):
            desired = .continuousSpeech
        case (false, _):
            desired = .speechEnd
        }

        if desired != self.currentValue {
            let interval: TimeInterval = switch desired {
            case .speechStart: self.speechStartInterval
            case .continuousSpeech: self.continuousSpeechInterval
            case .speechEnd: 0
            }
            if let last = self.lastChangeTime,
               now.timeIntervalSince(last) < interval {
                return self.currentValue
            }
            self.currentValue = desired
            self.lastChangeTime = now
        }

        return self.currentValue
    }
}

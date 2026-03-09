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
/// The value only changes at most every `minChangeInterval`.
class AudioActivityStateMachine {
    private let minChangeInterval: TimeInterval

    init(minChangeInterval: TimeInterval) {
        self.minChangeInterval = minChangeInterval
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
            // Rate limit changes.
            if let last = self.lastChangeTime,
               now.timeIntervalSince(last) < self.minChangeInterval {
                return self.currentValue
            }
            self.currentValue = desired
            self.lastChangeTime = now
        }

        return self.currentValue
    }
}

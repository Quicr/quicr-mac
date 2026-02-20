// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Values for the AudioActivityIndicator extension header.
enum AudioActivityValue: UInt8 {
    case speechEnd = 0
    case speechStart = 1
    case continuousSpeech = 2
}

/// Action returned by the state machine on each update.
enum AudioActivityAction {
    /// Include the extension with this value on the current frame/object.
    case sendExtension(AudioActivityValue)
    /// Publish normally, no extension needed.
    case none
    /// No speech activity to report (silence).
    case silent
}

/// Converts raw VAD booleans into timed AudioActivityIndicator signals.
///
/// The state machine is media-agnostic. The caller decides what to do
/// with subgroups (audio: no changes; video: roll subgroupId).
class AudioActivityStateMachine {
    static let continuousInterval: TimeInterval = 0.3
    static let endRepeatDuration: TimeInterval = 0.5

    private enum State {
        case idle
        case speaking(since: Date, lastContinuous: Date)
        case endingSpeech(since: Date)
    }

    private var state: State = .idle

    /// Process a VAD sample and return the action to take.
    func update(voiceActive: Bool, now: Date) -> AudioActivityAction {
        switch self.state {
        case .idle:
            if voiceActive {
                self.state = .speaking(since: now, lastContinuous: now)
                return .sendExtension(.speechStart)
            }
            return .silent

        case .speaking(let since, let lastContinuous):
            if voiceActive {
                let elapsed = now.timeIntervalSince(lastContinuous)
                if elapsed >= Self.continuousInterval {
                    self.state = .speaking(since: since, lastContinuous: now)
                    return .sendExtension(.continuousSpeech)
                }
                return .none
            } else {
                self.state = .endingSpeech(since: now)
                return .sendExtension(.speechEnd)
            }

        case .endingSpeech(let since):
            if voiceActive {
                self.state = .speaking(since: now, lastContinuous: now)
                return .sendExtension(.speechStart)
            }
            let elapsed = now.timeIntervalSince(since)
            if elapsed >= Self.endRepeatDuration {
                self.state = .idle
                return .silent
            }
            return .sendExtension(.speechEnd)
        }
    }
}

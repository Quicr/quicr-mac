// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Values for the AudioActivityIndicator extension header.
enum AudioActivityValue: UInt8, Comparable {
    static func < (lhs: AudioActivityValue, rhs: AudioActivityValue) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    case speechEnd = 0
    case speechStart = 2
    case continuousSpeech = 1
}

/// State machine for voice activity / active speaker.
class AudioActivityStateMachine {
    /// How long VAD must be continuously active before entering speechStart.
    private let timeToSpeechStart: TimeInterval
    /// How long VAD must be continuously active (while in speechStart) before promoting to continuousSpeech.
    private let timeToContinuous: TimeInterval
    /// How long VAD must be continuously silent before dropping from speechStart to speechEnd.
    private let timeToDropStart: TimeInterval
    /// How long VAD must be continuously silent before dropping from continuousSpeech to speechEnd.
    private let timeToDropContinuous: TimeInterval

    init(timeToSpeechStart: TimeInterval,
         timeToContinuous: TimeInterval,
         timeToDropStart: TimeInterval,
         timeToDropContinuous: TimeInterval) {
        self.timeToSpeechStart = timeToSpeechStart
        self.timeToContinuous = timeToContinuous
        self.timeToDropStart = timeToDropStart
        self.timeToDropContinuous = timeToDropContinuous
    }

    private var state: AudioActivityValue = .speechEnd
    private var voiceOnset: Date?
    private var silenceOnset: Date?

    /// Process a VAD sample and return the value to send on this object.
    func update(voiceActive: Bool, now: Date) -> AudioActivityValue {
        // Track when the current run of voice/silence began.
        if voiceActive {
            // We're talking.
            self.silenceOnset = nil
            if self.voiceOnset == nil {
                // We just started talking.
                self.voiceOnset = now
            }
        } else {
            // We're not talking.
            self.voiceOnset = nil
            if self.silenceOnset == nil {
                // We just stopped talking.
                self.silenceOnset = now
            }
        }

        switch self.state {
        case .speechEnd:
            if let onset = self.voiceOnset,
               now.timeIntervalSince(onset) >= self.timeToSpeechStart {
                // We weren't talking and now we are.
                self.state = .speechStart
                self.voiceOnset = now
            }

        case .speechStart:
            if let onset = self.voiceOnset,
               now.timeIntervalSince(onset) >= self.timeToContinuous {
                // We'e been talking for a while.
                self.state = .continuousSpeech
            } else if let onset = self.silenceOnset,
                      now.timeIntervalSince(onset) >= self.timeToDropStart {
                // We were talking, but we've not been for a while.
                self.state = .speechEnd
            }

        case .continuousSpeech:
            if let onset = self.silenceOnset,
               now.timeIntervalSince(onset) >= self.timeToDropContinuous {
                // We were talking, but we've not been for a while.
                self.state = .speechEnd
            }
        }

        return self.state
    }
}

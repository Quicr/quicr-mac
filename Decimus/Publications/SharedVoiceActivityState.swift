// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

/// Thread-safe produce/consume holder for voice activity state
/// shared between OpusPublication (producer) and H264Publication (consumer).
class SharedVoiceActivityState {
    private let pending: Mutex<AudioActivityValue?>

    init() {
        self.pending = .init(nil)
    }

    /// Called by OpusPublication when the state machine fires a state change.
    func postActivity(_ value: AudioActivityValue) {
        self.pending.withLock { $0 = value }
    }

    /// Called by H264Publication to consume the latest activity value.
    /// Returns nil if no new activity has been posted since the last consume.
    func consumeActivity() -> AudioActivityValue? {
        self.pending.withLock { current in
            let value = current
            current = nil
            return value
        }
    }
}

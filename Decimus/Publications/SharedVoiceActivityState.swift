// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

class SharedVoiceActivityState {
    private let pending: Mutex<AudioActivityValue?>
    private var lastResult: AudioActivityValue?

    init() {
        self.pending = .init(nil)
    }

    func postActivity(_ value: AudioActivityValue) {
        self.pending.withLock { $0 = value }
    }

    /// Consume state.
    func consumeActivity() -> AudioActivityValue? {
        self.pending.withLock { current in
            guard current != self.lastResult else { return nil }
            self.lastResult = current
            return current
        }
    }
}

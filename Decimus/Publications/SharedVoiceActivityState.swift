// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

class SharedVoiceActivityState {
    private let pending: Mutex<AudioActivityValue?>

    init() {
        self.pending = .init(nil)
    }

    func postActivity(_ value: AudioActivityValue) {
        self.pending.withLock { $0 = value }
    }

    /// Consume state.
    func consumeActivity() -> AudioActivityValue? {
        self.pending.withLock { current in
            let result = current
            current = nil
            return result
        }
    }
}

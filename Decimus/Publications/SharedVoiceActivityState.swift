// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

final class SharedVoiceActivityState: Sendable {
    private let pending: Mutex<AudioActivityValue?>

    init() {
        self.pending = .init(nil)
    }

    func postActivity(_ value: AudioActivityValue) {
        self.pending.withLock { $0 = value }
    }

    /// Read the latest posted activity value without clearing it.
    /// Multiple readers will all see the same value.
    func latestActivity() -> AudioActivityValue? {
        self.pending.withLock { $0 }
    }
}

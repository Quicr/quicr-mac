// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

extension Mutex {
    /// Return the value managed by the Mutex.
    public func get() -> Value {
        self.withLock { $0 }
    }

    /// Set the value of the mutex to nil.
    public func clear<Wrapped>() where Value == Wrapped? {
        self.withLock { $0 = .none }
    }

    /// Consume the value of the mutex, setting it to nil.
    /// - Returns The current value.
    public func consume<Wrapped>() -> Value where Value == Wrapped? {
        self.withLock { locked in
            let consumed = locked
            locked = .none
            return consumed
        }
    }
}

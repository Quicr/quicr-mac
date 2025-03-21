// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

extension Mutex {
    /// Return the value managed by the Mutex.
    public func get() -> Value {
        self.withLock { $0 }
    }
}

extension Mutex where Value: ExpressibleByNilLiteral {
    /// Set the value of the mutex to nil.
    public func clear() {
        self.withLock { $0 = nil }
    }
}

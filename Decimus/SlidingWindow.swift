// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import DequeModule
import os

/// Container for a sliding time window of values
/// whose validity is determined by age.
class SlidingTimeWindow<T: Numeric> {
    private var values: Deque<(timestamp: Date, value: T)>
    private let length: TimeInterval
    private let lock = OSAllocatedUnfairLock()

    /// Create a new sliding time window.
    /// - Parameter length: The length of the window.
    /// - Parameter reserved: Optionally, capacity to reserve in elements.
    init(length: TimeInterval, reserved: Int? = nil) {
        self.length = length
        self.values = .init(minimumCapacity: reserved ?? 0)
    }

    /// Add a timestamped value to the window.
    /// - Parameters:
    ///  - timestamp: The timestamp of the value.
    ///  - value: The value to add.
    func add(timestamp: Date, value: T) {
        self.lock.withLock {
            self.values.append((timestamp, value))
        }
    }

    /// Given a point in time, return all older values within the window.
    /// - Parameter from: The time from which the window will start.
    /// - Returns: An array of values no older than the window.
    func get(from: Date) -> [T] {
        self.lock.withLock {
            var toRemove = IndexSet()
            for index in self.values.indices {
                let element = self.values[index]
                guard from.timeIntervalSince(element.timestamp) > self.length else { break }
                toRemove.insert(index)
            }
            self.values.remove(atOffsets: toRemove)
            return self.values.reduce(into: []) { $0.append($1.value) }
        }
    }
}

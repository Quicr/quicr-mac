// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import DequeModule
import Synchronization

/// Container for a sliding time window of values
/// whose validity is determined by age.
class SlidingTimeWindow<T: Numeric> {
    private let values: Mutex<Deque<(timestamp: Date, value: T)>>
    private let length: TimeInterval

    /// Create a new sliding time window.
    /// - Parameter length: The length of the window.
    /// - Parameter reserved: Optionally, capacity to reserve in elements.
    init(length: TimeInterval, reserved: Int? = nil) {
        self.length = length
        self.values = .init(.init(minimumCapacity: reserved ?? 0))
    }

    /// Add a timestamped value to the window.
    /// - Parameters:
    ///  - timestamp: The timestamp of the value.
    ///  - value: The value to add.
    func add(timestamp: Date, value: T) {
        self.values.withLock { $0.append((timestamp, value)) }
    }

    /// Given a point in time, return all older values within the window.
    /// - Parameter from: The time from which the window will start.
    /// - Returns: An array of values no older than the window.
    func get(from: Date) -> [T] {
        self.values.withLock { values in
            var toRemove = IndexSet()
            for index in values.indices {
                let element = values[index]
                guard from.timeIntervalSince(element.timestamp) > self.length else { break }
                toRemove.insert(index)
            }
            values.remove(atOffsets: toRemove)
            return values.reduce(into: []) { $0.append($1.value) }
        }
    }
}

extension Collection where Element: SignedNumeric & Comparable {
    /// Returns the element with the smallest absolute value, or nil if the collection is empty.
    func closestToZero() -> Element? {
        return self.min { abs($0) < abs($1) }
    }
}

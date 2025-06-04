// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import DequeModule
import Synchronization

/// Container for a sliding time window of values
/// whose validity is determined by age.
class SlidingTimeWindow<T: Numeric> {
    private let values: Mutex<Deque<(timestamp: Date, value: T)>>
    let windowSize: TimeInterval

    /// Create a new sliding time window.
    /// - Parameter length: The length of the window.
    /// - Parameter reserved: Optionally, capacity to reserve in elements.
    init(length: TimeInterval, reserved: Int? = nil) {
        self.windowSize = length
        self.values = .init(.init(minimumCapacity: reserved ?? 0))
    }

    /// Add a timestamped value to the window.
    /// - Parameters:
    ///  - timestamp: The timestamp of the value.
    ///  - value: The value to add.
    func add(timestamp: Date, value: T) {
        self.values.withLock { $0.append((timestamp, value)) }
    }

    /// Get the latest value in the window.
    /// - Returns: The latest timestamp and value, or nil if the window is empty.
    func latest() -> (Date, T)? {
        self.values.withLock { $0.last }
    }

    /// Clear all the values in the window.
    func clear() {
        self.values.withLock { $0.removeAll(keepingCapacity: true) }
    }

    /// Given a point in time, return all older values within the window.
    /// - Parameter from: The time from which the window will start.
    /// - Returns: An array of values no older than the window.
    func get(from: Date) -> [T] {
        self.values.withLock { values in
            var toRemove = IndexSet()
            for index in values.indices {
                let element = values[index]
                guard from.timeIntervalSince(element.timestamp) > self.windowSize else { break }
                toRemove.insert(index)
            }
            values.remove(atOffsets: toRemove)
            return values.reduce(into: []) { $0.append($1.value) }
        }
    }

    /// The current number of elements in the window.
    /// - Returns: The number of elements currently in the window.
    func length() -> Int {
        self.values.withLock { $0.count }
    }
}

extension Collection where Element: SignedNumeric & Comparable {
    /// Returns the element with the smallest absolute value, or nil if the collection is empty.
    func closestToZero() -> Element? {
        return self.min { abs($0) < abs($1) }
    }
}

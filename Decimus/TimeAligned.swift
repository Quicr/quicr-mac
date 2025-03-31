// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

protocol TimeAlignerSet {
    var alignables: [TimeAlignable] { get }
}

class TimeAlignable {
    var jitterBuffer: JitterBuffer?
    let timeDiff = TimeDiff()
    private let logger = DecimusLogger(TimeAlignable.self)

    /// Calculates the time until the next frame would be expected, or nil if there is no next frame.
    /// - Parameter from: The time to calculate from.
    /// - Returns Time to wait in seconds, if any.
    func calculateWaitTime(from: Date) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else { return nil }
        guard let diff = self.timeDiff.getTimeDiff() else { return nil }
        return jitterBuffer.calculateWaitTime(from: from, offset: diff)
    }

    func calculateWaitTime(item: JitterBuffer.JitterItem, from: Date = .now) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else {
            assert(false)
            self.logger.error("App misconfiguration, please report this")
            return nil
        }
        guard let diff = self.timeDiff.getTimeDiff() else { return nil }
        return jitterBuffer.calculateWaitTime(item: item, from: from, offset: diff)
    }
}

struct TimeDiff: ~Copyable {
    private let timestampTimeDiffUs = Atomic(Int128.zero)

    /// Set the difference in time between incoming stream timestamps and wall clock.
    /// - Parameter diff: Difference in time in seconds.
    func setTimeDiff(diff: TimeInterval) {
        // Get to an integer representation, in microseconds.
        let diffUs = Int128(diff * microsecondsPerSecond)
        // 0 is unset, so if we happen to get zero we'll just take the 1us hit.
        self.timestampTimeDiffUs.store(diffUs != 0 ? diffUs : 1, ordering: .releasing)
    }

    func getTimeDiff() -> TimeInterval? {
        let diffUs = self.timestampTimeDiffUs.load(ordering: .acquiring)
        guard diffUs != 0 else { return nil }
        return TimeInterval(diffUs) / microsecondsPerSecond
    }
}

final class TimeAligner {
    private let timestampTimeDiff = Atomic<Int128>(0)
    private let diffWindow: SlidingTimeWindow<TimeInterval>
    private var windowMaintenance: Task<(), Never>?
    private let set: TimeAlignerSet

    init(windowLength: TimeInterval, capacity: Int, set: TimeAlignerSet) {
        self.diffWindow = .init(length: windowLength, reserved: capacity)
        self.set = set
    }

    private func doWindowMaintenance(when: Date) -> TimeInterval? {
        let values = self.diffWindow.get(from: when)
        guard let calculated = values.closestToZero() else {
            self.timestampTimeDiff.store(0, ordering: .releasing)
            return nil
        }
        self.timestampTimeDiff.store(Int128(calculated * microsecondsPerSecond), ordering: .releasing)
        print(calculated)
        return calculated
    }

    func doTimestampTimeDiff(_ timestamp: TimeInterval, when: Date) {
        // Record this diff.
        let diff = when.timeIntervalSince1970 - timestamp
        self.diffWindow.add(timestamp: when, value: diff)

        // Kick off a task for sliding window.
        if self.windowMaintenance == nil {
            self.windowMaintenance = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    if let self = self,
                       let value = self.doWindowMaintenance(when: Date.now) {
                        for alignable in self.set.alignables {
                            alignable.timeDiff.setTimeDiff(diff: value)
                        }
                    } else {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }

        // If we have nothing, start with this.
        if self.timestampTimeDiff.load(ordering: .acquiring) == 0 {
            if let value = self.doWindowMaintenance(when: when) {
                for alignable in set.alignables {
                    alignable.timeDiff.setTimeDiff(diff: value)
                }
            }
        }
    }
}

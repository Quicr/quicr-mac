// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

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
    typealias GetAlignables = () -> [TimeAlignable]
    private let getAlignables: GetAlignables

    init(windowLength: TimeInterval, capacity: Int, alignables: @escaping GetAlignables) {
        self.diffWindow = .init(length: windowLength, reserved: capacity)
        self.getAlignables = alignables
    }

    private func doWindowMaintenance(when: Date) -> TimeInterval? {
        let values = self.diffWindow.get(from: when)
        guard let calculated = values.closestToZero() else {
            self.timestampTimeDiff.store(0, ordering: .releasing)
            return nil
        }
        self.timestampTimeDiff.store(Int128(calculated * microsecondsPerSecond), ordering: .releasing)
        return calculated
    }

    func doTimestampTimeDiff(_ timestamp: TimeInterval, when: Date, force: Bool = false) {
        // Record this diff.
        let diff = when.timeIntervalSince1970 - timestamp
        self.diffWindow.add(timestamp: when, value: diff)

        // Kick off a task for sliding window.
        if !force && self.windowMaintenance == nil {
            self.windowMaintenance = .init(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    if let self = self {
                        self.set(.now)
                    } else {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }

        // If we have nothing, start with this.
        if force || self.timestampTimeDiff.load(ordering: .acquiring) == 0 {
            self.set(when)
        }
    }

    private func set(_ date: Date) {
        guard let value = self.doWindowMaintenance(when: date) else { return }
        for alignable in self.getAlignables() {
            alignable.timeDiff.setTimeDiff(diff: value)
        }
    }
}

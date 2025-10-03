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
    func calculateWaitTime(from: When) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else { return nil }
        guard let diff = self.timeDiff.getTimeDiff() else { return nil }
        return jitterBuffer.calculateWaitTime(from: from, offset: diff)
    }

    func calculateWaitTime(item: JitterBuffer.JitterItem, from: When) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else {
            assert(false)
            self.logger.error("App misconfiguration, please report this")
            return nil
        }
        guard let diff = self.timeDiff.getTimeDiff() else { return nil }
        return jitterBuffer.calculateWaitTime(item: item, from: from, offset: diff)
    }
}

/// Represents the offset needed to convert sender timestamps to our monotonic timeline.
struct HostTimeOffset {
    /// Reference point sender timestamp.
    let senderTimestamp: TimeInterval
    /// Receiver host at reference point.
    let receiverHostTime: Ticks

    /// Convert a sender timestamp to receiver host time.
    /// - Parameter senderTime: Sender timestamp.
    /// - Returns: Corresponding receiver host time.
    func toReceiverHost(_ senderTime: TimeInterval) -> Ticks {
        let deltaSender = senderTime - self.senderTimestamp
        return self.receiverHostTime &+ deltaSender.ticks
    }
}

struct TimeDiff: ~Copyable {
    private let atomicPair = Atomic<WordPair>(.init(first: 0, second: 0))

    /// Set the difference in time between incoming stream timestamps and wall clock.
    /// - Parameters:
    ///   - senderTimestamp: Sender timestamp in Unix epoch seconds.
    ///   - receiverHostTime: Receiver mHostTime when packet arrived (ticks).
    func setTimeDiff(senderTimestamp: TimeInterval, receiverHostTime: Ticks) {
        let senderUs = UInt(senderTimestamp * microsecondsPerSecond)
        // 0 is unset, so if we happen to get zero we'll just take the 1us hit.
        self.atomicPair.store(.init(first: senderUs != 0 ? senderUs : 1, second: UInt(receiverHostTime)), ordering: .releasing)
    }

    /// Get the monotonic time offset for converting sender timestamps.
    /// - Returns: Offset struct if set, nil otherwise.
    func getTimeDiff() -> HostTimeOffset? {
        let pair = self.atomicPair.load(ordering: .acquiring)
        let senderUs = pair.first
        let receiverHost = pair.second
        guard senderUs != 0 else { return nil }
        let senderTimestamp = TimeInterval(senderUs) / microsecondsPerSecond
        return HostTimeOffset(senderTimestamp: senderTimestamp, receiverHostTime: Int128(receiverHost))
    }
}

struct HostTimeEntry {
    let senderTimestamp: TimeInterval
    let receiverHostTime: Ticks
    let receiverDate: Date
}

final class TimeAligner {
    private let hostTimeWindow: Mutex<[(timestamp: Date, entry: HostTimeEntry)]>
    private let windowLength: TimeInterval
    private var windowMaintenance: Task<(), Never>?
    typealias GetAlignables = () -> [TimeAlignable]
    private let getAlignables: GetAlignables

    init(windowLength: TimeInterval, capacity: Int, alignables: @escaping GetAlignables) {
        self.hostTimeWindow = .init([])
        self.windowLength = windowLength
        self.getAlignables = alignables
    }

    private func doWindowMaintenance(when: Date) -> HostTimeEntry? {
        self.hostTimeWindow.withLock { entries in
            entries.removeAll { when.timeIntervalSince($0.timestamp) > self.windowLength }

            guard !entries.isEmpty else { return nil }

            return entries.map { $0.entry }.min { lhs, rhs in
                let lhsDiff = abs(lhs.receiverDate.timeIntervalSince1970 - lhs.senderTimestamp)
                let rhsDiff = abs(rhs.receiverDate.timeIntervalSince1970 - rhs.senderTimestamp)
                return lhsDiff < rhsDiff
            }
        }
    }

    func doTimestampTimeDiff(_ timestamp: TimeInterval, when: Date, force: Bool = false) {
        let whenHost = Ticks(mach_absolute_time())

        let hostEntry = HostTimeEntry(senderTimestamp: timestamp,
                                      receiverHostTime: whenHost,
                                      receiverDate: when)
        self.hostTimeWindow.withLock { $0.append((timestamp: when, entry: hostEntry)) }

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

        if force || self.hostTimeWindow.withLock({ $0.count == 1 }) {
            self.set(when)
        }
    }

    private func set(_ date: Date) {
        guard let hostEntry = self.doWindowMaintenance(when: date) else { return }

        for alignable in self.getAlignables() {
            alignable.timeDiff.setTimeDiff(senderTimestamp: hostEntry.senderTimestamp,
                                           receiverHostTime: hostEntry.receiverHostTime)
        }
    }
}

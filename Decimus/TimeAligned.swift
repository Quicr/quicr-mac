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
    func calculateWaitTime(from: Ticks) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else { return nil }
        guard let diff = self.timeDiff.getTimeDiff() else { return nil }
        return jitterBuffer.calculateWaitTime(from: from, offset: diff)
    }

    func calculateWaitTime(item: JitterBuffer.JitterItem, from: Ticks) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else {
            assert(false)
            self.logger.error("App misconfiguration, please report this")
            return nil
        }
        guard let diff = self.timeDiff.getTimeDiff() else { return nil }
        return jitterBuffer.calculateWaitTime(item: item, from: from, offset: diff)
    }
}

/// Represents the offset needed to convert sender timestamps to monotonic timeline.
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
        return .init(SignedTicks(self.receiverHostTime) + deltaSender.signedTicks)
    }
}

struct TimeDiff: ~Copyable {
    private let atomicPair = Atomic<WordPair>(.init(first: 0, second: 0))

    /// Set the difference in time between incoming stream timestamps and wall clock.
    /// - Parameters:
    ///   - senderTimestamp: Sender timestamp in Unix epoch seconds.
    ///   - receiverHostTime: Receiver mHostTime when packet arrived (ticks).
    func setTimeDiff(diff: HostTimeOffset) {
        let senderNs = UInt(diff.senderTimestamp * nanosecondsPerSecond)
        // 0 is unset, so if we happen to get zero we'll just take the 1ns hit.
        self.atomicPair.store(.init(first: senderNs != 0 ? senderNs : 1,
                                    second: UInt(diff.receiverHostTime)),
                              ordering: .releasing)
    }

    /// Get the monotonic time offset for converting sender timestamps.
    /// - Returns: Offset struct if set, nil otherwise.
    func getTimeDiff() -> HostTimeOffset? {
        let pair = self.atomicPair.load(ordering: .acquiring)
        let senderNs = pair.first
        let receiverHost = pair.second
        guard senderNs != 0 else { return nil }
        let senderTimestamp = TimeInterval(senderNs) / nanosecondsPerSecond
        return HostTimeOffset(senderTimestamp: senderTimestamp, receiverHostTime: Ticks(receiverHost))
    }
}

final class TimeAligner {
    private let hostTimeWindow: Mutex<[HostTimeOffset]>
    private let windowLength: TimeInterval
    private var windowMaintenance: Task<(), Never>?
    typealias GetAlignables = () -> [TimeAlignable]
    private let getAlignables: GetAlignables

    init(windowLength: TimeInterval, capacity: Int, alignables: @escaping GetAlignables) {
        self.hostTimeWindow = .init([])
        self.windowLength = windowLength
        self.getAlignables = alignables
    }

    private func doWindowMaintenance(when: Ticks) -> HostTimeOffset? {
        // Look at all the times in our window.
        // The smallest diff between sender and receiver time is our best
        // estimate of the correct offset, as live media cannot arrive early.
        self.hostTimeWindow.withLock { entries in
            entries.removeAll { when.timeIntervalSince($0.receiverHostTime) > self.windowLength }
            guard !entries.isEmpty else { return nil }
            return entries.min { lhs, rhs in
                let lhsDiff = lhs.receiverHostTime.seconds - lhs.senderTimestamp
                let rhsDiff = rhs.receiverHostTime.seconds - rhs.senderTimestamp
                return lhsDiff < rhsDiff
            }
        }
    }

    func doTimestampTimeDiff(_ timestamp: TimeInterval, when: Ticks, force: Bool = false) {
        let offset = HostTimeOffset(senderTimestamp: timestamp,
                                    receiverHostTime: when)
        self.hostTimeWindow.withLock { $0.append(offset) }

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

    private func set(_ date: Ticks) {
        guard let hostEntry = self.doWindowMaintenance(when: date) else { return }

        for alignable in self.getAlignables() {
            alignable.timeDiff.setTimeDiff(diff: hostEntry)
        }
    }
}

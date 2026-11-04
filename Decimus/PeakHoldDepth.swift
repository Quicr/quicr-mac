// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

/// Sizes a jitter buffer target from the worst recent lateness of objects relative to their
/// expected arrival time and decays back down.
struct PeakHoldDepth {
    /// Time to keep target raised.
    private let hold: TimeInterval
    /// Lowest possible target.
    private let floor: TimeInterval
    /// Max possible target.
    private let ceiling: TimeInterval
    /// Headroom above peak.
    private let margin: TimeInterval
    /// Seconds removed per second once peak ages out.
    private let decayRate: TimeInterval
    /// Worst lateness for each whole second of arrival time, oldest first.
    private var peaks: [(second: TimeInterval, lateness: TimeInterval)] = []
    /// Time of last arrived frame.
    private var lastArrival: Ticks?
    /// Current buffer target.
    private var target: TimeInterval

    /// - Parameters:
    ///   - initial: Target before any arrivals.
    ///   - hold: Whole seconds a peak keeps the target raised.
    ///   - floor: Lowest target in seconds.
    ///   - ceiling: Highest target in seconds.
    ///   - margin: Headroom above the held peak in seconds.
    ///   - decayRate: Seconds of target removed per second once peaks age out.
    init(initial: TimeInterval,
         hold: TimeInterval = 10,
         floor: TimeInterval = 0.03,
         ceiling: TimeInterval = 0.5,
         margin: TimeInterval = 0.01,
         decayRate: TimeInterval = 0.02) {
        self.target = initial
        self.hold = hold
        self.floor = floor
        self.ceiling = ceiling
        self.margin = margin
        self.decayRate = decayRate
    }

    /// Record an arrival.
    /// - Parameters:
    ///   - lateness: How much later than its expected arrival time the object arrived, in seconds.
    ///   - arrival: When the object arrived.
    /// - Returns: The updated target depth in seconds.
    mutating func update(lateness: TimeInterval, arrival: Ticks) -> TimeInterval {
        let second = arrival.seconds
        if let last = self.peaks.last, last.second == second {
            self.peaks[self.peaks.count - 1].lateness = max(last.lateness, lateness)
        } else {
            self.peaks.append((second, lateness))
        }
        self.peaks.removeAll { $0.second <= second - self.hold }

        let peak = self.peaks.reduce(lateness) { max($0, $1.lateness) }
        let required = min(self.ceiling, max(self.floor, peak + self.margin))
        if required >= self.target {
            self.target = required
        } else if let lastArrival = self.lastArrival {
            let decayed = self.target - self.decayRate * arrival.timeIntervalSince(lastArrival)
            self.target = max(required, decayed)
        }
        self.lastArrival = arrival
        return self.target
    }
}

/// Synchronize buffer targets across multiple subscriptions.
final class SharedPeakHoldDepth: Sendable {
    private struct State {
        var first: PeakHoldDepth
        var any: PeakHoldDepth
        var firstTarget: TimeInterval
        var anyTarget: TimeInterval
        var newestTimestamp: TimeInterval?
    }

    // TODO: Compute from observed variance.
    /// Allow this much time for all to arrive.
    private let allowance: TimeInterval

    private let state: Mutex<State>

    /// - Parameters:
    ///   - initial: Target before any arrivals.
    ///   - allowance: Longest additional delay to wait for layers that arrive after the first, in seconds.
    init(initial: TimeInterval, allowance: TimeInterval = 0.1) {
        self.allowance = allowance
        self.state = .init(.init(first: .init(initial: initial),
                                 any: .init(initial: initial),
                                 firstTarget: initial,
                                 anyTarget: initial))
    }

    /// Record an arrival on any layer.
    /// - Parameters:
    ///   - timestamp: Presentation timestamp of the object, shared by every layer's encoding of the same frame.
    ///   - lateness: How much later than its expected arrival time the object arrived, in seconds.
    ///   - arrival: When the object arrived.
    /// - Returns: The target depth for every layer, in seconds.
    func update(timestamp: TimeInterval, lateness: TimeInterval, arrival: Ticks) -> TimeInterval {
        self.state.withLock { state in
            if state.newestTimestamp.map({ timestamp > $0 }) ?? true {
                state.newestTimestamp = timestamp
                state.firstTarget = state.first.update(lateness: lateness, arrival: arrival)
            }
            state.anyTarget = state.any.update(lateness: lateness, arrival: arrival)
            return min(state.anyTarget, state.firstTarget + self.allowance)
        }
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Sizes a jitter buffer target from the worst recent lateness of objects relative to their
/// expected arrival time.
///
/// The target rises immediately to cover a new peak, holds while peaks recur within the hold window,
/// and then decays at a limited rate.
struct PeakHoldDepth {
    private let hold: Int
    private let floor: TimeInterval
    private let ceiling: TimeInterval
    private let margin: TimeInterval
    private let decayRate: Double
    /// Worst lateness for each whole second of arrival time, oldest first.
    private var peaks: [(second: Int, lateness: TimeInterval)] = []
    private var lastArrival: Ticks?
    private var target: TimeInterval

    /// - Parameters:
    ///   - initial: Target before any arrivals.
    ///   - hold: Whole seconds a peak keeps the target raised.
    ///   - floor: Lowest target in seconds.
    ///   - ceiling: Highest target in seconds.
    ///   - margin: Headroom above the held peak in seconds.
    ///   - decayRate: Seconds of target removed per second once peaks age out.
    init(initial: TimeInterval,
         hold: Int = 10,
         floor: TimeInterval = 0.03,
         ceiling: TimeInterval = 0.5,
         margin: TimeInterval = 0.01,
         decayRate: Double = 0.02) {
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
        let second = Int(arrival.seconds)
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

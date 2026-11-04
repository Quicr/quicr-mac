// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Shared timeline for time-aligned subscriptions.
final class PlayoutTimeline: Sendable {
    /// Offset from sender timestamps to receiver host time.
    let timeDiff = TimeDiff()
    /// Peak-hold jitter buffer target depth.
    let depth: SharedPeakHoldDepth
    /// Spread of decode completion times across layers.
    let decodedVariances: VarianceCalculator

    init(depth: SharedPeakHoldDepth, decodedVariances: VarianceCalculator) {
        self.depth = depth
        self.decodedVariances = decodedVariances
    }
}

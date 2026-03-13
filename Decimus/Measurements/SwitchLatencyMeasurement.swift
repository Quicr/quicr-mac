// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Measurement actor for switch_latency InfluxDB measurement.
/// One point emitted per completed top-n switch event.
actor SwitchLatencyMeasurement: Measurement {
    let id = UUID()
    var name: String = "switch_latency"
    var fields: Fields = [:]
    var tags: [String: String] = [:]

    /// Record a completed switch event with all phase durations.
    /// - Parameters:
    ///   - context: The accumulated switch context with all phase timestamps.
    ///   - renderTime: When the first frame was enqueued for display (captured on main thread).
    ///   - participant: The participant ID string for the track.
    func record(context: SwitchContext, renderTime: Date, participant: String) {
        guard let joinStrategy = context.joinStrategy,
              let joinDecisionTime = context.joinDecisionTime,
              let joinCompleteTime = context.joinCompleteTime,
              let decodeTime = context.decodeTime else {
            return
        }

        let perPointTags: [String: String] = [
            "participant": participant,
            "activation_type": context.activationType.rawValue,
            "join_strategy": joinStrategy.rawValue
        ]

        let activationToJoinDecisionMs = joinDecisionTime.timeIntervalSince(context.activationTime) * 1000.0
        let joinExecutionMs = joinCompleteTime.timeIntervalSince(joinDecisionTime) * 1000.0
        let decodeMs = decodeTime.timeIntervalSince(joinCompleteTime.hostDate) * 1000.0
        let renderMs = renderTime.timeIntervalSince(decodeTime) * 1000.0
        let totalSwitchMs = renderTime.timeIntervalSince(context.activationTime.hostDate) * 1000.0

        record(field: "group_depth",
               value: context.groupDepth as AnyObject,
               timestamp: renderTime,
               tags: perPointTags)
        record(field: "activation_to_join_decision_ms",
               value: activationToJoinDecisionMs,
               timestamp: renderTime,
               tags: perPointTags)
        record(field: "join_execution_ms",
               value: joinExecutionMs,
               timestamp: renderTime,
               tags: perPointTags)
        record(field: "fetch_object_count",
               value: (context.fetchObjectCount ?? 0) as AnyObject,
               timestamp: renderTime,
               tags: perPointTags)
        record(field: "decode_ms",
               value: decodeMs,
               timestamp: renderTime,
               tags: perPointTags)
        record(field: "render_ms",
               value: renderMs,
               timestamp: renderTime,
               tags: perPointTags)
        record(field: "total_switch_ms",
               value: totalSwitchMs,
               timestamp: renderTime,
               tags: perPointTags)
    }
}

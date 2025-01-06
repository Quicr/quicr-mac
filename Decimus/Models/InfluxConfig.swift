// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Configuration for an influx server to receive metrics with.
struct InfluxConfig: Codable {
    /// True to actually collect and submit metrics.
    var submit: Bool  = false
    /// True to record metrics at a granular level. Possible performance impact.
    var granular: Bool = false
    /// True to emit metrics during a call, false to batch them until the end.
    var realtime: Bool = false
    /// Full URL of the target influx server.
    var url: String = "http://metrics.m10x.ctgpoc.com:8086"
    /// Bucket to use.
    var bucket: String = "Media10x"
    /// Org to use.
    var org: String = "Cisco"
    /// Interval at which to collect up metrics when ``submit`` is true.
    var intervalSecs: Int = 5
}

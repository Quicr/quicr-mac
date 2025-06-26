// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreAudio

// Cached time constants.
private let bootDate = Date.now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
private let timebase: TimeInterval = {
    var info = mach_timebase_info_data_t()
    let result = mach_timebase_info(&info)
    guard result == KERN_SUCCESS,
          info.denom > 0 else {
        fatalError("Failed to get timebase info: \(result)")
    }
    return TimeInterval(info.numer) / (TimeInterval(info.denom) * 1_000_000_000.0)
}()

/// Convert a HAL host time to a ``Date``.
/// - Parameter hostTime: The host time value to convert.
/// - Returns: A ``Date`` object representing the audio date corresponding to the host time.
@inline(__always)
func hostToDate(_ hostTime: UInt64) -> Date {
    let interval = TimeInterval(hostTime) * timebase
    return bootDate.addingTimeInterval(interval)
}

/// Convert a ``Date`` to a HAL host time.
/// - Parameter date: The ``Date`` object to convert.
/// - Returns: A host time value representing the audio date.
@inline(__always)
func dateToHost(_ date: Date) -> UInt64 {
    let hostTime = date.timeIntervalSince(bootDate) / timebase
    return UInt64(hostTime)
}

// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreAudio

// Cached time constants.
private let bootDate = Date.now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
let microsecondsPerSecond: TimeInterval = 1_000_000
let nanosecondsPerSecond: TimeInterval = 1e-9
private let timebase: TimeInterval = {
    var info = mach_timebase_info_data_t()
    let result = mach_timebase_info(&info)
    guard result == KERN_SUCCESS,
          info.denom > 0 else {
        fatalError("Failed to get timebase info: \(result)")
    }
    return TimeInterval(info.numer) / (TimeInterval(info.denom) * nanosecondsPerSecond)
}()

/// Get the current monotonic host time.
/// - Returns: Current host time in ticks.
@inline(__always)
func getCurrentHostTime() -> UInt64 {
    return mach_absolute_time()
}

/// Convert host time ticks to seconds.
/// - Parameter hostTime: The duration in host time ticks.
/// - Returns: The duration in seconds.
@inline(__always)
func hostTimeToSeconds(_ hostTime: any BinaryInteger) -> TimeInterval {
    return TimeInterval(hostTime) * timebase
}

/// Convert seconds to host time ticks.
/// - Parameter seconds: The duration in seconds.
/// - Returns: The duration in host time ticks.
@inline(__always)
func secondsToHostTime<T: BinaryInteger>(_ seconds: TimeInterval) -> T {
    return T(seconds / timebase)
}

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

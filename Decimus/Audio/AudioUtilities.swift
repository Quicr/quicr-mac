// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreAudio

typealias Ticks = UInt64
typealias SignedTicks = Int64

private extension BinaryInteger {
    var seconds: TimeInterval {
        TimeInterval(self) * timebase
    }
}

extension Ticks {
    static var now: Ticks {
        Ticks(mach_absolute_time())
    }

    func timeIntervalSince(_ since: Ticks) -> TimeInterval {
        (SignedTicks(self) - SignedTicks(since)).seconds
    }

    var seconds: TimeInterval {
        TimeInterval(self) * timebase
    }

    var hostDate: Date {
        self.seconds.hostDate
    }
}

extension TimeInterval {
    /// Get this time interval in signed ticks.
    var signedTicks: SignedTicks {
        SignedTicks(self / timebase)
    }

    /// Convert to host time ticks.
    var ticks: Ticks {
        Ticks(self / timebase)
    }

    /// Convert host time seconds to Date.
    var hostDate: Date {
        bootDate.addingTimeInterval(self)
    }
}

// Cached time constants.
private let bootDate = Date.now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
let microsecondsPerSecond: TimeInterval = 1e6
let nanosecondsPerSecond: TimeInterval = 1e9
private let timebase: TimeInterval = {
    var info = mach_timebase_info_data_t()
    let result = mach_timebase_info(&info)
    guard result == KERN_SUCCESS,
          info.denom > 0 else {
        fatalError("Failed to get timebase info: \(result)")
    }
    return TimeInterval(info.numer) / (TimeInterval(info.denom) * nanosecondsPerSecond)
}()

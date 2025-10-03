// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreAudio

typealias Ticks = Int128

extension TimeInterval {
    /// Convert to host time ticks.
    var ticks: Ticks {
        Ticks(self / timebase)
    }

    /// Convert host time seconds to Date.
    var hostDate: Date {
        bootDate.addingTimeInterval(self)
    }
}

extension BinaryInteger {
    var seconds: TimeInterval {
        TimeInterval(self) * timebase
    }

    var hostDate: Date {
        self.seconds.hostDate
    }
}

struct When {
    let date: Date
    let ticks: Ticks

    init() {
        self.date = .now
        self.ticks = Ticks(mach_absolute_time())
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

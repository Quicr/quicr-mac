// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
import Testing
import Numerics
@testable import QuicR

struct TestTimeDiff {
    @Test("Get/Set", arguments: [-100, -0.1, 0.1, 100])
    func getSetPositive(value: TimeInterval) {
        let diff = TimeDiff()
        diff.setTimeDiff(diff: value)
        #expect(diff.getTimeDiff() == value)
    }

    @Test("Unset")
    func getUnset() {
        #expect(TimeDiff().getTimeDiff() == nil)
    }
}

private let minDepth: TimeInterval = 0.2
struct TestTimeAlignable {
    private class TimeAlignableImpl: TimeAlignable, TimeAlignerSet {
        var alignables: [TimeAlignable] { [self] }
        override init() {
            let handlers = CMBufferQueue.Handlers { builder in
                builder.compare { _, _ in
                    .compareLessThan
                }
                builder.getDecodeTimeStamp { _ in
                    .invalid
                }
                builder.getDuration { _ in
                    .invalid
                }
                builder.getPresentationTimeStamp {
                    (($0) as! JitterBuffer.JitterItem).timestamp // swiftlint:disable:this force_cast
                }
                builder.getSize { _ in
                    0
                }
                builder.isDataReady { _ in
                    true
                }
            }
            super.init()
            self.jitterBuffer = try? .init(identifier: "Test",
                                           metricsSubmitter: nil,
                                           minDepth: minDepth,
                                           capacity: 5,
                                           handlers: handlers)
        }
    }

    class JitterItemImpl: JitterBuffer.JitterItem {
        let sequenceNumber: UInt64
        let timestamp: CMTime
        init(sequenceNumber: UInt64, timestamp: Date) {
            self.sequenceNumber = sequenceNumber
            let value = timestamp.timeIntervalSince1970 * microsecondsPerSecond
            self.timestamp = .init(value: CMTimeValue(value), timescale: CMTimeScale(microsecondsPerSecond))
        }
    }

    @Test("Alignment")
    func align() throws {
        let alignable = TimeAlignableImpl()
        let now = Date.now
        let item = JitterItemImpl(sequenceNumber: 0, timestamp: now)
        let aligner = TimeAligner(windowLength: 5, capacity: 5, set: alignable)
        aligner.doTimestampTimeDiff(item.timestamp.seconds, when: now, force: true)
        try alignable.jitterBuffer!.write(item: item, from: now)

        // Now should be min wait time.
        let waitTime = alignable.calculateWaitTime(from: now)
        #expect(waitTime != nil)
        #expect(waitTime!.isApproximatelyEqual(to: minDepth,
                                               absoluteTolerance: 1/1000))

        // Later should be ealier.
        let after: TimeInterval = 0.1
        let waitTimeAfter = alignable.calculateWaitTime(from: now.addingTimeInterval(after))
        #expect(waitTimeAfter != nil)
        #expect(waitTimeAfter!.isApproximatelyEqual(to: minDepth.advanced(by: -after),
                                                    absoluteTolerance: 1/1000))

        // A delay should not mess with the estimate. 50ms later sample arriving 100ms later (50ms late).
        let captureTime = now.addingTimeInterval(0.05)
        let secondDelayedSampled = JitterItemImpl(sequenceNumber: 1,
                                                  timestamp: captureTime)
        let arrivalTime = now.addingTimeInterval(0.1) // 50ms later sample + 50ms delay.
        try alignable.jitterBuffer!.write(item: secondDelayedSampled, from: arrivalTime)
        aligner.doTimestampTimeDiff(secondDelayedSampled.timestamp.seconds, when: arrivalTime, force: true)
        let _: JitterItemImpl? = alignable.jitterBuffer!.read(from: arrivalTime)
        let waitTimeLate = alignable.calculateWaitTime(from: arrivalTime)

        #expect(waitTimeLate != nil)
        #expect(waitTimeLate!.isApproximatelyEqual(to: minDepth.advanced(by: -0.05),
                                                   absoluteTolerance: 1/1000))
    }
}

// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import CoreMedia
import Synchronization

// swiftlint:disable force_cast

/// Possible errors thrown by ``JitterBuffer``
enum JitterBufferError: Error {
    /// The buffer was full and this sample couldn't be enqueued.
    case full
    case old
}

/// A very simplified jitter buffer designed to contain compressed frames in order.
class JitterBuffer {

    /// Jiitter buffer configuration.
    struct Config: Codable {
        /// The mode of operation.
        var mode: Mode = .none
        /// The initial target & minimum depth frames will be delayed for.
        var minDepth: TimeInterval = 0.2
        /// The maximum storage capacity of the jitter buffer.
        var capacity: TimeInterval = 5
        /// The window over which jitter is calculated.
        var window: TimeInterval = 5
        /// Dynamically adjust target depth.
        var adaptive: Bool = true
        /// WiFi spike prediction.
        var spikePrediction: Bool = false
    }

    /// Possible modes of jitter buffer usage.
    enum Mode: CaseIterable, Identifiable, Codable {
        /// Use a PID controller to maintain target depth.
        case pid
        /// Attempt to schedule individual frames to be played out according to their timestamp.
        case interval
        /// Delegate timing control to `AVSampleBufferDisplayLayer`
        case layer
        /// No jitter buffer, play frames syncronously on receive.
        case none
        var id: Self { self }
    }

    private static let logger = DecimusLogger(JitterBuffer.self)
    private let baseTargetDepthUs: Atomic<UInt64>
    private let adjustmentTargetDepthUs: Atomic<UInt64>
    private var buffer: CMBufferQueue
    private let measurement: MeasurementRegistration<JitterBufferMeasurement>?
    private let playingFromStart: Bool
    private let play: Atomic<Bool>
    private let lastSequenceRead = Atomic<UInt64>(0)
    private let lastSequenceSet = Atomic<Bool>(false)

    protocol JitterItem: AnyObject {
        var sequenceNumber: UInt64 { get }
        var timestamp: CMTime { get }
    }

    /// Create a new video jitter buffer.
    /// This jitter buffer has 3 notions of depth: Target base, target actual, and current depth.
    ///     Target base: The unadjusted target depth / delay.
    ///     Target actual: The adjusted target depth / delay.
    ///     Current depth: The current duration of media in the buffer.
    /// - Parameter identifier: Label for this buffer.
    /// - Parameter metricsSubmitter: Optionally, an object to submit metrics through.
    /// - Parameter minDepth: Starting target base depth in seconds.
    /// - Parameter capacity: Capacity in number of buffers / elements.
    /// - Parameter handlers: CMBufferQueue.Handlers implementation to use.
    init(identifier: String,
         metricsSubmitter: MetricsSubmitter?,
         minDepth: TimeInterval,
         capacity: Int,
         handlers: CMBufferQueue.Handlers,
         playingFromStart: Bool = true) throws {
        self.buffer = try .init(capacity: capacity, handlers: handlers)
        if let metricsSubmitter = metricsSubmitter {
            let measurement = JitterBufferMeasurement(namespace: identifier)
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.baseTargetDepthUs = .init(.init(minDepth * microsecondsPerSecond))
        self.adjustmentTargetDepthUs = .init(0)
        self.playingFromStart = playingFromStart
        self.play = .init(playingFromStart)
    }

    /// Set the buffer's target base depth.
    /// This is the depth that the buffer will attempt to maintain, but may temporarily be adjusted.
    /// Adjustments will return to this value.
    /// - Parameter depth: The target depth in seconds.
    func setBaseTargetDepth(_ depth: TimeInterval) {
        self.baseTargetDepthUs.store(UInt64(depth * microsecondsPerSecond), ordering: .releasing)
    }

    /// Get the base target depth of the buffer.
    /// - Returns: The base target depth in seconds.
    func getBaseTargetDepth() -> TimeInterval {
        TimeInterval(self.baseTargetDepthUs.load(ordering: .acquiring)) / microsecondsPerSecond
    }

    /// Set the buffer's current target depth adjustment.
    /// This is the resultant depth that the buffer will currently target.
    /// Caller's should only use this for adjustments, and should reset to 0.
    func setTargetAdjustment(_ adjustment: TimeInterval) {
        self.adjustmentTargetDepthUs.store(UInt64(adjustment * microsecondsPerSecond), ordering: .releasing)
    }

    /// Get the current target depth of the buffer (including any adjustment).
    /// - Returns: The current target depth in seconds.
    func getCurrentTargetDepth() -> TimeInterval {
        let target = self.getBaseTargetDepth()
        let adjustment = TimeInterval(self.adjustmentTargetDepthUs.load(ordering: .acquiring)) / microsecondsPerSecond
        return target + adjustment
    }

    /// Allow frames to be dequeued from the buffer.
    /// You should only call this if ``self.playingFromStart`` was set to false.
    func startPlaying() {
        assert(!self.playingFromStart)
        self.play.store(true, ordering: .releasing)
    }

    /// Write a video frame into the jitter buffer.
    /// Write should not be called concurrently with another write.
    /// - Parameter videoFrame: The sample to attempt to sort into the buffer.
    /// - Throws: Buffer is full, or video frame is older than last read.
    func write<T: JitterItem>(item: T, from: Date) throws {
        // Check expiry.
        if self.lastSequenceSet.load(ordering: .acquiring) {
            guard item.sequenceNumber > self.lastSequenceRead.load(ordering: .acquiring) else {
                throw JitterBufferError.old
            }
        }

        do {
            try self.buffer.enqueue(item)
        } catch let error as NSError {
            guard error.code == -12764 else { throw error }
            throw JitterBufferError.full
        }

        // Metrics.
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.write(timestamp: from)
            }
        }
    }

    /// Attempt to read a frame from the front of the buffer.
    /// - Parameter from: The timestamp of this read operation.
    /// This is an optimization to reduce the number of now() calculations,
    /// and has no bearing on jitter buffer behaviour.
    /// - Returns: Either the oldest available frame, or nil.
    func read<T: JitterItem>(from: Date) -> T? {
        // If we're not playing, do nothing.
        if !self.playingFromStart {
            guard self.play.load(ordering: .acquiring) else { return nil }
        }

        let depth: TimeInterval? = self.measurement != nil ? self.buffer.duration.seconds : nil

        // Ensure there's something to get.
        guard let oldest = self.buffer.dequeue() else {
            if let measurement = self.measurement {
                Task(priority: .utility) {
                    await measurement.measurement.currentDepth(depth: depth!, timestamp: from)
                    await measurement.measurement.underrun(timestamp: from)
                }
            }
            return nil
        }
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.currentDepth(depth: depth!, timestamp: from)
                await measurement.measurement.read(timestamp: from)
            }
        }
        let item = oldest as! T
        self.lastSequenceRead.store(item.sequenceNumber, ordering: .releasing)
        self.lastSequenceSet.store(true, ordering: .releasing)
        return item
    }

    /// Empty the buffer.
    func clear() throws {
        try self.buffer.reset()
    }

    func updateLastSequenceRead(_ seq: UInt64) {
        self.lastSequenceRead.store(seq, ordering: .releasing)
    }

    /// Get the CMBuffer at the front of the buffer without removing it.
    /// - Returns: The head of the buffer, if any.
    func peek<T: JitterItem>() -> T? {
        self.buffer.head as! T?
    }

    /// Get the current depth of the queue (sum of all contained durations).
    /// - Returns: Duration in seconds.
    func getDepth() -> TimeInterval {
        self.buffer.duration.seconds
    }

    /// Get the point in time this item should ideally be played out.
    /// - Parameter item: The item to calculate the playout date for.
    /// - Parameter offset: Offset from the start point at which media starts.
    /// - Parameter since: The start point of the media timeline.
    /// - Returns: The date at which this item should be played out.
    func getPlayoutDate(item: JitterItem,
                        offset: TimeInterval,
                        since: Date = .init(timeIntervalSince1970: 0)) -> Date {
        let actualTargetDepth = self.getCurrentTargetDepth()
        return Date(timeInterval: item.timestamp.seconds.advanced(by: offset), since: since) + actualTargetDepth
    }

    /// Calculate the estimated time interval until this frame should be rendered.
    /// - Parameter frame: The frame to calculate the wait time for.
    /// - Parameter from: The time to calculate the time interval from.
    /// - Parameter offset: Offset from the start point at which media starts.
    /// - Parameter since: The start point of the media timeline.
    /// - Returns: The time to wait, or nil if no estimation can be made. (There is no next frame).
    func calculateWaitTime(item: JitterItem,
                           from: Date,
                           offset: TimeInterval,
                           since: Date = .init(timeIntervalSince1970: 0)) -> TimeInterval {
        let targetDate = self.getPlayoutDate(item: item, offset: offset, since: since)
        let waitTime = targetDate.timeIntervalSince(from)
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.measurement.waitTime(value: waitTime, timestamp: from)
            }
        }
        return waitTime
    }

    /// Calculate the estimated time interval until the next frame should be rendered.
    /// - Parameter from: The time to calculate the time interval from.
    /// - Parameter offset: Offset from the start point at which media starts.
    /// - Parameter since: The start point of the media timeline.
    /// - Returns: The time to wait, or nil if no estimation can be made. (There is no next frame).
    func calculateWaitTime(from: Date,
                           offset: TimeInterval,
                           since: Date = .init(timeIntervalSince1970: 0)) -> TimeInterval? {
        guard let peek = self.buffer.head else { return nil }
        let item = peek as! JitterItem
        return self.calculateWaitTime(item: item, from: from, offset: offset, since: since)
    }
}

// swiftlint:enable force_cast

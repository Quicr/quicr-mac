// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import OrderedCollections
import AVFoundation
import Atomics

// swiftlint:disable force_cast

/// Possible errors thrown by ``JitterBuffer``
enum JitterBufferError: Error {
    /// The buffer was full and this sample couldn't be enqueued.
    case full
    case old
}

/// A very simplified jitter buffer designed to contain compressed video frames in order.
class JitterBuffer {

    /// Jiitter buffer configuration.
    struct Config: Codable {
        /// The mode of operation.
        var mode: Mode = .none
        /// The initial target & minimum depth frames will be delayed for.
        var minDepth: TimeInterval = 0.2
        /// The maximum storage capacity of the jitter buffer.
        var capacity: TimeInterval = 2
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
    private let minDepth: TimeInterval
    private var buffer: CMBufferQueue
    private let measurement: MeasurementRegistration<JitterBufferMeasurement>?
    private var play: Bool = false
    private var lastSequenceRead = ManagedAtomic<UInt64>(0)
    private var lastSequenceSet = ManagedAtomic<Bool>(false)

    protocol JitterItem: AnyObject {
        var sequenceNumber: UInt64 { get }
        var timestamp: CMTime { get }
    }

    /// Create a new video jitter buffer.
    /// - Parameter identifier: Label for this buffer.
    /// - Parameter metricsSubmitter: Optionally, an object to submit metrics through.
    /// - Parameter minDepth: Fixed initial & target delay in seconds.
    /// - Parameter capacity: Capacity in number of buffers / elements.
    /// - Parameter handlers: CMBufferQueue.Handlers implementation to use.
    init(identifier: String,
         metricsSubmitter: MetricsSubmitter?,
         minDepth: TimeInterval,
         capacity: Int,
         handlers: CMBufferQueue.Handlers) throws {
        self.buffer = try .init(capacity: capacity, handlers: handlers)
        if let metricsSubmitter = metricsSubmitter {
            let measurement = JitterBufferMeasurement(namespace: identifier)
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.minDepth = minDepth
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
    /// This is an optimization to reduce the number of now() calculations, and has no bearing on jitter buffer behaviour.
    /// - Returns: Either the oldest available frame, or nil.
    func read<T: JitterItem>(from: Date) -> T? {
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
        let targetDate = Date(timeInterval: item.timestamp.seconds.advanced(by: offset), since: since)
        let waitTime = targetDate.timeIntervalSince(from) + self.minDepth
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

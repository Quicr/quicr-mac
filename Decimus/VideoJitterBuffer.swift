// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import OrderedCollections
import AVFoundation
import Atomics

// swiftlint:disable force_cast

/// Possible errors thrown by ``VideoJitterBuffer``
enum VideoJitterBufferError: Error {
    /// The buffer was full and this sample couldn't be enqueued.
    case full
}

/// A very simplified jitter buffer designed to contain compressed video frames in order.
class VideoJitterBuffer {

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

    private static let logger = DecimusLogger(VideoJitterBuffer.self)
    private let minDepth: TimeInterval
    private var buffer: CMBufferQueue
    private let measurement: MeasurementRegistration<VideoJitterBufferMeasurement>?
    private var play: Bool = false
    private var lastSequenceRead = ManagedAtomic<UInt64>(0)
    private var lastSequenceSet = ManagedAtomic<Bool>(false)

    /// Create a new video jitter buffer.
    /// - Parameter fullTrackName: The namespace of the video this buffer is used for, for identification purposes.
    /// - Parameter metricsSubmitter: Optionally, an object to submit metrics through.
    /// - Parameter sort: True to actually sort on sequence number, false if they're already in order.
    /// - Parameter minDepth: Fixed initial & target delay in seconds.
    /// - Parameter capacity: Capacity in number of buffers / elements.
    init(fullTrackName: FullTrackName,
         metricsSubmitter: MetricsSubmitter?,
         sort: Bool,
         minDepth: TimeInterval,
         capacity: Int) throws {
        let handlers = CMBufferQueue.Handlers { builder in
            builder.compare {
                if !sort {
                    return .compareLessThan
                }
                let first = $0 as! DecimusVideoFrame
                let second = $1 as! DecimusVideoFrame
                guard let seq1 = first.sequenceNumber,
                      let seq2 = second.sequenceNumber else {
                    Self.logger.error("Samples were missing sequence number")
                    return .compareLessThan
                }
                if seq1 < seq2 {
                    return .compareLessThan
                } else if seq1 > seq2 {
                    return .compareGreaterThan
                } else if seq1 == seq2 {
                    return .compareEqualTo
                }
                assert(false)
                return .compareLessThan
            }
            builder.getDecodeTimeStamp {
                ($0 as! DecimusVideoFrame).samples.first?.decodeTimeStamp ?? .invalid
            }
            builder.getDuration {
                ($0 as! DecimusVideoFrame).samples.first?.duration ?? .invalid
            }
            builder.getPresentationTimeStamp {
                ($0 as! DecimusVideoFrame).samples.first?.presentationTimeStamp ?? .invalid
            }
            builder.getSize {
                ($0 as! DecimusVideoFrame).samples.reduce(0) { $0 + $1.totalSampleSize }
            }
            builder.isDataReady {
                ($0 as! DecimusVideoFrame).samples.reduce(true) { $0 && $1.dataReadiness == .ready }
            }
        }
        self.buffer = try .init(capacity: capacity, handlers: handlers)
        if let metricsSubmitter = metricsSubmitter {
            let measurement = VideoJitterBufferMeasurement(namespace: try fullTrackName.getNamespace())
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
    func write(videoFrame: DecimusVideoFrame, from: Date) throws {
        // Check expiry.
        if let thisSeq = videoFrame.sequenceNumber,
           self.lastSequenceSet.load(ordering: .acquiring) {
            guard thisSeq > self.lastSequenceRead.load(ordering: .acquiring) else {
                throw "Refused enqueue as older than last read"
            }
        }

        do {
            try self.buffer.enqueue(videoFrame)
        } catch let error as NSError {
            guard error.code == -12764 else { throw error }
            throw VideoJitterBufferError.full
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
    func read(from: Date) -> DecimusVideoFrame? {
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
        let sample = oldest as! DecimusVideoFrame
        if let sequenceNumber = sample.sequenceNumber {
            self.lastSequenceRead.store(sequenceNumber, ordering: .releasing)
            self.lastSequenceSet.store(true, ordering: .releasing)
        }
        return sample
    }

    /// Get the CMBuffer at the front of the buffer without removing it.
    /// - Returns: The head of the buffer, if any.
    func peek() -> CMBuffer? {
        self.buffer.head
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
    func calculateWaitTime(frame: DecimusVideoFrame,
                           from: Date,
                           offset: TimeInterval,
                           since: Date = .init(timeIntervalSince1970: 0)) -> TimeInterval {
        guard let sample = frame.samples.first else {
            // TODO: Ensure we cannot enqueue a frame with no samples to make this a valid error.
            fatalError()
        }
        let timestamp = sample.presentationTimeStamp
        let targetDate = Date(timeInterval: timestamp.seconds.advanced(by: offset), since: since)
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
        let frame = peek as! DecimusVideoFrame
        return self.calculateWaitTime(frame: frame, from: from, offset: offset, since: since)
    }
}

// swiftlint:enable force_cast

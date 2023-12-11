import Foundation
import OrderedCollections
import AVFoundation

// swiftlint:disable force_cast

/// A very simplified jitter buffer designed to contain compressed video frames in order.
class VideoJitterBuffer {

    struct Config: Codable {
        var mode: Mode = .none
        var minDepth: TimeInterval = 0.2
    }

    enum Mode: CaseIterable, Identifiable, Codable {
        case pid
        case interval
        case layer
        case none
        var id: Self { self }
    }

    private actor _Measurement: Measurement {
        var name: String = "VideoJitterBuffer"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var underruns: UInt64 = 0
        private var readAttempts: UInt64 = 0
        private var writes: UInt64 = 0
        private var flushed: UInt64 = 0

        init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
            tags["namespace"] = namespace
            Task(priority: .utility) {
                await submitter.register(measurement: self)
            }
        }

        func currentDepth(depth: TimeInterval, timestamp: Date?) {
            record(field: "currentDepth", value: UInt32(depth * 1000) as AnyObject, timestamp: timestamp)
        }

        func underrun(timestamp: Date?) {
            self.underruns += 1
            record(field: "underruns", value: self.underruns as AnyObject, timestamp: timestamp)
        }

        func write(timestamp: Date?) {
            self.writes += 1
            record(field: "writes", value: self.writes as AnyObject, timestamp: timestamp)
        }

        func flushed(count: UInt, timestamp: Date?) {
            self.flushed += UInt64(count)
            record(field: "flushed", value: self.flushed as AnyObject, timestamp: timestamp)
        }
    }

    private static let logger = DecimusLogger(VideoJitterBuffer.self)
    private let minDepth: TimeInterval
    private var buffer: CMBufferQueue
    private let frameDuration: TimeInterval
    private let measurement: _Measurement?
    private var play: Bool = false
    private var playToken: CMBufferQueueTriggerToken?
    private var lastSequenceRead: UInt64?
    private var timestampTimeDiff: TimeInterval?

    /// Create a new video jitter buffer.
    /// - Parameter namespace The namespace of the video this buffer is used for, for identification purposes.
    /// - Parameter frameDuration The duration of the video frames contained within the buffer.
    /// - Parameter metricsSubmitter Optionally, an object to submit metrics through.
    /// - Parameter sort True to actually sort on sequence number, false if they're already in order.
    /// - Parameter config Jitter buffer configuration.
    /// - Parameter frameAvailable Callback with a paced frame to render.
    init(namespace: QuicrNamespace,
         frameDuration: TimeInterval,
         metricsSubmitter: MetricsSubmitter?,
         sort: Bool,
         minDepth: TimeInterval) throws {
        self.frameDuration = frameDuration
        let handlers = CMBufferQueue.Handlers { builder in
            builder.compare {
                if !sort {
                    return .compareLessThan
                }
                let first = $0 as! CMSampleBuffer
                let second = $1 as! CMSampleBuffer
                guard let seq1 = first.getSequenceNumber(),
                      let seq2 = second.getSequenceNumber() else {
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
                ($0 as! CMSampleBuffer).decodeTimeStamp
            }
            builder.getDuration {
                ($0 as! CMSampleBuffer).duration
            }
            builder.getPresentationTimeStamp {
                ($0 as! CMSampleBuffer).presentationTimeStamp
            }
            builder.getSize {
                ($0 as! CMSampleBuffer).totalSampleSize
            }
            builder.isDataReady {
                ($0 as! CMSampleBuffer).dataReadiness == .ready
            }
        }
        self.buffer = try .init(capacity: Int(ceil(minDepth / frameDuration) * 10), handlers: handlers)
        if let metricsSubmitter = metricsSubmitter {
            measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            measurement = nil
        }
        self.minDepth = minDepth
        self.playToken = try self.buffer.installTrigger(condition: .whenDurationBecomesGreaterThanOrEqualTo(.init(seconds: minDepth,
                                                                                                                  preferredTimescale: 1)), { _ in
                                                                                                                    self.play = true
                                                                                                                  })
    }

    /// Write a video frame into the jitter buffer.
    /// Write should not be called concurrently with another write.
    /// - Parameter videoFrame The sample to attempt to sort into the buffer.
    func write(videoFrame: CMSampleBuffer) throws {
        // Save starting time.
        if self.timestampTimeDiff == nil {
            self.timestampTimeDiff = Date.now.timeIntervalSinceReferenceDate - videoFrame.presentationTimeStamp.seconds
        }

        // Check expiry.
        if let thisSeq = videoFrame.getSequenceNumber(),
           let lastSequenceRead = self.lastSequenceRead {
            guard thisSeq > lastSequenceRead else {
                throw "Refused enqueue as older than last read"
            }
        }

        try self.buffer.enqueue(videoFrame)

        // Metrics.
        if let measurement = self.measurement {
            let now: Date = .now
            Task(priority: .utility) {
                await measurement.write(timestamp: now)
            }
        }
    }

    /// Attempt to read a frame from the front of the buffer.
    /// - Returns Either the oldest available frame, or nil.
    func read() -> CMSampleBuffer? {
        let now: Date = .now
        let depth: TimeInterval = self.buffer.duration.seconds
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.currentDepth(depth: depth, timestamp: now)
            }
        }

        // Are we playing out?
        guard self.play else {
            return nil
        }

        // We won't stop.
        if let playToken = self.playToken {
            do {
                try self.buffer.removeTrigger(playToken)
            } catch {
                Self.logger.error("Failed to remove playout trigger: \(error.localizedDescription)")
            }
            self.playToken = nil
        }

        // Ensure there's something to get.
        guard let oldest = self.buffer.dequeue() else {
            if let measurement = self.measurement {
                Task(priority: .utility) {
                    await measurement.underrun(timestamp: now)
                }
            }
            return nil
        }
        let sample = oldest as! CMSampleBuffer
        self.lastSequenceRead = sample.getSequenceNumber()
        return sample
    }

    /// Flush the jitter buffer until the target group is at the front, or there are no more frames left.
    /// - Parameter targetGroup The group to flush frames up until.
    func flushTo(targetGroup groupId: UInt32) {
        var flushCount: UInt = 0
        while let frame = self.buffer.head,
              let thisGroupId = (frame as! CMSampleBuffer).getGroupId(),
              thisGroupId < groupId {
            guard let flushed = self.buffer.dequeue() else {
                break
            }
            self.lastSequenceRead = (flushed as! CMSampleBuffer).getSequenceNumber()
            flushCount += 1
        }

        if let measurement = self.measurement {
            let now: Date = .now
            let metric = flushCount
            Task(priority: .utility) {
                await measurement.flushed(count: metric, timestamp: now)
            }
        }
    }

    func getDepth() -> TimeInterval {
        self.buffer.duration.seconds
    }

    func calculateWaitTime() -> TimeInterval {
        calculateWaitTime(from: .now)
    }

    func calculateWaitTime(from: Date) -> TimeInterval {
        guard let peek = self.buffer.head,
              let diff = self.timestampTimeDiff else {
            return self.frameDuration
        }
        let sample = peek as! CMSampleBuffer
        let timestampValue = sample.presentationTimeStamp.seconds
        let targetTimeRef = timestampValue + diff
        let targetDate = Date(timeIntervalSinceReferenceDate: targetTimeRef)
        return targetDate.timeIntervalSinceNow + self.minDepth
    }
}

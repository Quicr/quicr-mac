import Foundation
import OrderedCollections

/// A very simplified jitter buffer designed to contain compressed video frames in order.
class VideoJitterBuffer {

    struct Config: Codable {
        var mode: Mode = .none
        var minDepth: TimeInterval = 0.2
    }

    enum Mode: CaseIterable, Identifiable, Codable {
        case pid; case interval; case none
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

    private let minDepth: TimeInterval
    private var buffer: OrderedSet<VideoFrame>
    private let frameDuration: TimeInterval
    private let lock: NSLock = .init()
    private let measurement: _Measurement?
    private var play: Bool = false
    private var lastSequenceRead: UInt64?
    private let sort: Bool

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
         minDepth: TimeInterval) {
        self.frameDuration = frameDuration
        self.buffer = .init(minimumCapacity: Int(ceil(minDepth / frameDuration)))
        if let metricsSubmitter = metricsSubmitter {
            measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            measurement = nil
        }
        self.sort = sort
        self.minDepth = minDepth
    }

    /// Write a video frame into the jitter buffer.
    /// Write should not be called concurrently with another write.
    /// - Parameter videoFrame The video frame structure to attempt to sort into the buffer.
    /// - Returns True if successfully enqueued, false if it was older than the last read and thus dropped.
    func write(videoFrame: VideoFrame) -> Bool {
        let result = lock.withLock {
            let thisSeq = videoFrame.getSeq()
            if let lastSequenceRead = self.lastSequenceRead {
                guard thisSeq > lastSequenceRead else {
                    print("[VideoJitterBuffer] Skipping \(thisSeq), had \(lastSequenceRead)")
                    return false
                }
            }
            self.buffer.append(videoFrame)
            if self.sort {
                self.buffer.sort()
            }
            return true
        }

        // Metrics.
        if let measurement = self.measurement {
            let now: Date = .now
            Task(priority: .utility) {
                await measurement.write(timestamp: now)
            }
        }
        return result
    }

    /// Attempt to read a frame from the front of the buffer.
    /// - Returns Either the oldest available frame, or nil.
    func read() -> VideoFrame? {
        let now: Date = .now
        let count = self.lock.withLock {
            self.buffer.count
        }

        let depth: TimeInterval = TimeInterval(count) * self.frameDuration
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.currentDepth(depth: depth, timestamp: now)
            }
        }

        // Are we playing out?
        if !self.play && depth > self.minDepth {
            self.play = true
        }
        guard self.play else {
            return nil
        }

        // Ensure there's something to get.
        guard count > 0 else {
            if let measurement = self.measurement {
                Task(priority: .utility) {
                    await measurement.underrun(timestamp: now)
                }
            }
            return nil
        }

        // Get the oldest available frame.
        return self.lock.withLock {
            let oldest = self.buffer.removeFirst()
            self.lastSequenceRead = oldest.getSeq()
            return oldest
        }
    }

    /// Flush the jitter buffer until the target group is at the front, or there are no more frames left.
    /// - Parameter targetGroup The group to flush frames up until.
    func flushTo(targetGroup groupId: UInt32) {
        var flushCount: UInt = 0
        lock.withLock {
            while self.buffer.count > 0 && self.buffer[0].groupId < groupId {
                let flushed = self.buffer.removeFirst()
                self.lastSequenceRead = flushed.getSeq()
                flushCount += 1
            }
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
        self.lock.withLock {
            Double(self.buffer.count) * self.frameDuration
        }
    }
}

extension VideoFrame: Hashable, Comparable {
    static func < (lhs: VideoFrame, rhs: VideoFrame) -> Bool {
        lhs.getSeq() < rhs.getSeq()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(getSeq())
    }

    static func == (lhs: VideoFrame, rhs: VideoFrame) -> Bool {
        lhs.getSeq() == rhs.getSeq()
    }

    func getSeq() -> UInt64 {
        (UInt64(self.groupId) << 16) | UInt64(self.objectId)
    }
}

import Foundation
import OrderedCollections

/// A very simplified jitter buffer designed to contain compressed video frames in order.
class VideoJitterBuffer {

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
            record(field: "currentDepth", value: depth as AnyObject, timestamp: timestamp)
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

    private var buffer: OrderedSet<VideoFrame>
    private let frameDuration: TimeInterval
    private let minDepth: TimeInterval
    private let lock: NSLock = .init()
    private let measurement: _Measurement?
    private var play: Bool = false
    private var lastSequenceRead: UInt64?

    /// Create a new video jitter buffer.
    /// - Parameter namespace The namespace of the video this buffer is used for, for identification purposes.
    /// - Parameter frameDuration The duration of the video frames contained within the buffer.
    /// - Parameter minDepth The target depth of the jitter buffer in time.
    /// - Parameter metricsSubmitter Optionally, an object to submit metrics through.
    init(namespace: QuicrNamespace,
         frameDuration: TimeInterval,
         minDepth: TimeInterval,
         metricsSubmitter: MetricsSubmitter?) {
        self.frameDuration = frameDuration
        self.minDepth = minDepth
        self.buffer = .init(minimumCapacity: Int(ceil(minDepth / frameDuration)))
        if let metricsSubmitter = metricsSubmitter {
            measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            measurement = nil
        }
    }

    /// Write a video frame into the jitter buffer.
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
            return true
        }
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
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.currentDepth(depth: Double(self.buffer.count) * self.frameDuration,
                                               timestamp: now)
            }
        }

        return lock.withLock {
            // Ensure there's something to get.
            guard self.buffer.count > 0 else {
                if let measurement = self.measurement {
                    Task(priority: .utility) {
                        await measurement.underrun(timestamp: now)
                    }
                }
                return nil
            }

            // Is it time to play yet?
            if !play {
                let required: Int = .init(ceil(self.minDepth / self.frameDuration))
                guard self.buffer.count >= required else { return nil }
                play = true
            }

            // Get the oldest available frame.
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
}

extension VideoFrame: Hashable {
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

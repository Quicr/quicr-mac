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
    }

    private var buffer: OrderedSet<VideoFrame>
    private let frameDuration: TimeInterval
    private let minDepth: TimeInterval
    private let lock: NSLock = .init()
    private let measurement: _Measurement?
    private var play: Bool = false

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

    func write(videoFrame: VideoFrame) {
        lock.withLock { _ = self.buffer.append(videoFrame) }
        if let measurement = self.measurement {
            let now: Date = .now
            Task(priority: .utility) {
                await measurement.write(timestamp: now)
            }
        }
    }

    func read() -> VideoFrame? {
        let now: Date = .now
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.currentDepth(depth: Double(self.buffer.count) * self.frameDuration,
                                               timestamp: now)
            }
        }

        return lock.withLock {
            if !play {
                // Is it time to play yet?
                let required: Int = .init(ceil(self.minDepth / self.frameDuration))
                guard self.buffer.count >= required else { return nil }
                play = true
            }

            // Ensure there's something to get.
            guard self.buffer.count > 0 else {
                if let measurement = self.measurement {
                    Task(priority: .utility) {
                        await measurement.underrun(timestamp: now)
                    }
                }
                return nil
            }

            // Get the oldest available frame.
            return self.buffer.removeFirst()
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

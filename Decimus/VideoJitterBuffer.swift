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

    typealias FrameAvailble = (VideoFrame) -> Void
    private var buffer: OrderedSet<VideoFrame>
    private let frameDuration: TimeInterval
    private let minDepth: TimeInterval
    private let lock: NSLock = .init()
    private let measurement: _Measurement?
    private var play: Bool = false
    private var lastSequenceRead: UInt64?
    private let sort: Bool
    private let frameAvailable: FrameAvailble
    private var dequeueTask: Task<(),Never>?
    private let config: Config

    // PID tuning.
    private var kp: Double = 0.01
    private var ki: Double = 0.001
    private var kd: Double = 0.001
    private var integral: Double = 0
    private var lastError: Double = 0

    // Time calculation.
    private var firstWriteTime: Date?
    private var dequeuedCount: UInt = 0

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
         config: Config,
         frameAvailable: @escaping FrameAvailble) throws {
        self.frameDuration = frameDuration
        self.minDepth = config.minDepth
        self.buffer = .init(minimumCapacity: Int(ceil(minDepth / frameDuration)))
        if let metricsSubmitter = metricsSubmitter {
            measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            measurement = nil
        }
        self.sort = sort
        guard config.mode != .none else {
            throw "Jitter buffer shouldn't be created when mode none"
        }
        self.config = config
        self.frameAvailable = frameAvailable
    }

    /// Write a video frame into the jitter buffer.
    /// Write should not be called concurrently with another write.
    /// - Parameter videoFrame The video frame structure to attempt to sort into the buffer.
    /// - Returns True if successfully enqueued, false if it was older than the last read and thus dropped.
    func write(videoFrame: VideoFrame) -> Bool {
        let result = lock.withLock {
            if self.firstWriteTime == nil {
                self.firstWriteTime = .now
            }
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
            
        // Start the dequeue task if not already.
        if self.dequeueTask == nil {
            self.dequeueTask = .init(priority: .high) { [weak self] in
                while !Task.isCancelled {
                    guard let self = self else { return }

                    // Wait until we expect to have a frame available.
                    let waitTime = self.lock.withLock {
                        self.calculateWaitTime()
                    }
                    let ns = waitTime * 1_000_000_000
                    if ns > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(ns))
                    }

                    // Attempt to dequeue a frame.
                    self.lock.withLock {
                        if let frame = self.read() {
                            self.frameAvailable(frame)
                        }
                    }
                }
            }
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
    /// The lock should already be held by the caller.
    /// - Returns Either the oldest available frame, or nil.
    private func read() -> VideoFrame? {
        let now: Date = .now
        let depth: TimeInterval = TimeInterval(self.buffer.count) * self.frameDuration
        if let measurement = self.measurement {
            Task(priority: .utility) {
                await measurement.currentDepth(depth: depth, timestamp: now)
            }
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
        let oldest = self.buffer.removeFirst()
        self.lastSequenceRead = oldest.getSeq()
        self.dequeuedCount += 1
        return oldest
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
    
    private func calculateWaitTime() -> TimeInterval {
        switch self.config.mode {
        case .interval:
            Self.calculateWaitTimeInterval(firstWriteTime: self.firstWriteTime!,
                                           minDepth: self.minDepth,
                                           frameDuration: self.frameDuration,
                                           dequeuedCount: self.dequeuedCount)
        case .pid:
            Self.calculateWaitTimePid(currentDepth: Double(self.buffer.count) * self.frameDuration,
                                      targetDepth: self.minDepth,
                                      frameDuration: self.frameDuration,
                                      integral: &self.integral,
                                      lastError: &self.lastError,
                                      kp: self.kp,
                                      ki: self.ki,
                                      kd: self.kd)
        case .none:
            fatalError()
        }
    }
    
    private static func calculateWaitTimePid(currentDepth: TimeInterval,
                                             targetDepth: TimeInterval,
                                             frameDuration: TimeInterval,
                                             integral: inout Double,
                                             lastError: inout Double,
                                             kp: Double,
                                             ki: Double,
                                             kd: Double) -> TimeInterval {
        let error = targetDepth - currentDepth
        integral += error
        let derivative = error - lastError
        lastError = error
        return frameDuration + (kp * error + ki * integral + kd * derivative)
    }
    
    private static func calculateWaitTimeInterval(firstWriteTime: Date,
                                                  minDepth: TimeInterval,
                                                  frameDuration: TimeInterval,
                                                  dequeuedCount: UInt) -> TimeInterval {
        let expectedTime: Date = firstWriteTime + minDepth + (frameDuration * Double(dequeuedCount))
        return expectedTime.timeIntervalSinceNow
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

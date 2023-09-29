/// Provides the capability of calculating the wait time
/// between VideoJitterBuffer dequeues.
protocol VideoDequeuer {
    /// Return how long to wait before querying for a frame again.
    func calculateWaitTime() -> TimeInterval
}

/// Uses a PID controller to approach a target depth of the jitter buffer,
/// by altering the dequeue rate.
class PIDDequeuer: VideoDequeuer {
    /// Input: The current jitter buffer depth.
    var currentDepth: TimeInterval = 0
    private let targetDepth: TimeInterval
    private let frameDuration: TimeInterval
    private let kp: Double
    private let ki: Double
    private let kd: Double
    private var integral: Double = 0
    private var lastError: Double = 0

    /// Create a new PID controller.
    /// - Parameter targetDepth: The target depth the controller is attempting to reach.
    /// - Parameter frameDuration: The base dequeue rate / expected frame delta.
    /// - Parameter kp: Proportional coefficient.
    /// - Parameter ki: Integral coefficient.
    /// - Parameter kd: Derivative coefficients.
    init(targetDepth: TimeInterval, frameDuration: TimeInterval, kp: Double, ki: Double, kd: Double) {
        self.targetDepth = targetDepth
        self.frameDuration = frameDuration
        self.kp = kp
        self.ki = ki
        self.kd = kd
    }
    
    func calculateWaitTime() -> TimeInterval {
        let error = self.targetDepth - self.currentDepth
        self.integral += error
        let derivative = error - self.lastError
        self.lastError = error
        return frameDuration + (self.kp * error + self.ki * self.integral + self.kd * derivative)
    }
}

/// A VideoDequeuer that attempts to find the original dequeue interval
/// to the next frame.
class IntervalDequeuer: VideoDequeuer {
    /// Input: The number of dequeued frames.
    var dequeuedCount: UInt = 0
    private let minDepth: TimeInterval
    private let frameDuration: TimeInterval
    private let firstWriteTime: Date

    /// Create a new interval dequeuer.
    /// - Parameter minDepth: The minimum depth of the buffer. The first frame would be expected to be dequeued at firstWrite + minDepth.
    /// - Parameter frameDuration: The duration of each frame. Frame N = firstWrite + minDepth + (duration * count).
    /// - Parameter firstWriteTime: The time at which the first frame arrived.
    init(minDepth: TimeInterval, frameDuration: TimeInterval, firstWriteTime: Date) {
        self.minDepth = minDepth
        self.frameDuration = frameDuration
        self.firstWriteTime = firstWriteTime
    }

    /// Calculate the wait time for frame N = self.dequeuedCount from now.
    func calculateWaitTime() -> TimeInterval {
        calculateWaitTime(from: .now)
    }

    /// Calculate the wait time for frame N = self.dequeuedCount from the given reference date.
    func calculateWaitTime(from: Date) -> TimeInterval {
        let expectedTime: Date = self.firstWriteTime + self.minDepth + (self.frameDuration * Double(self.dequeuedCount))
        return expectedTime.timeIntervalSince(from)
    }
}

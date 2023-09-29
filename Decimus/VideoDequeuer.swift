protocol VideoDequeuer {
    func calculateWaitTime() -> TimeInterval
}

class PIDDequeuer: VideoDequeuer {
    var currentDepth: TimeInterval = 0
    private let targetDepth: TimeInterval
    private let frameDuration: TimeInterval
    private let kp: Double
    private let ki: Double
    private let kd: Double
    private var integral: Double = 0
    private var lastError: Double = 0
    
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

class IntervalDequeuer: VideoDequeuer {
    var dequeuedCount: UInt = 0
    private let minDepth: TimeInterval
    private let frameDuration: TimeInterval
    private let firstWriteTime: Date
    
    init(minDepth: TimeInterval, frameDuration: TimeInterval, firstWriteTime: Date) {
        self.minDepth = minDepth
        self.frameDuration = frameDuration
        self.firstWriteTime = firstWriteTime
    }
    
    func calculateWaitTime() -> TimeInterval {
        calculateWaitTime(from: .now)
    }
    
    func calculateWaitTime(from: Date) -> TimeInterval {
        let expectedTime: Date = self.firstWriteTime + self.minDepth + (self.frameDuration * Double(self.dequeuedCount))
        return expectedTime.timeIntervalSince(from)
    }
}

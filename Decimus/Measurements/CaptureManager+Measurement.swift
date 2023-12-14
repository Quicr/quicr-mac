extension CaptureManager {
    actor _Measurement: Measurement {
        var name: String = "CaptureManager"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var capturedFrames: UInt64 = 0
        private var dropped: UInt64 = 0
        private var captureDelay: Double = 0

        init(submitter: MetricsSubmitter) {
            Task {
                await submitter.register(measurement: self)
            }
        }

        func droppedFrame(timestamp: Date?) {
            self.dropped += 1
            record(field: "droppedFrames", value: self.dropped as AnyObject, timestamp: timestamp)
        }

        func capturedFrame(delayMs: Double?, timestamp: Date?) {
            self.capturedFrames += 1
            record(field: "capturedFrames", value: self.capturedFrames as AnyObject, timestamp: timestamp)
            if let delayMs = delayMs {
                record(field: "captureDelay", value: delayMs as AnyObject, timestamp: timestamp)
            }
        }
    }
}

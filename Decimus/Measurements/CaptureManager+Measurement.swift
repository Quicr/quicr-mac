extension CaptureManager {
    actor _Measurement: Measurement {
        let id = UUID()
        var name: String = "CaptureManager"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var capturedFrames: UInt64 = 0
        private var dropped: UInt64 = 0

        func droppedFrame(timestamp: Date?) {
            self.dropped += 1
            record(field: "droppedFrames", value: self.dropped as AnyObject, timestamp: timestamp)
        }

        func capturedFrame(timestamp: Date?) {
            self.capturedFrames += 1
            record(field: "capturedFrames", value: self.capturedFrames as AnyObject, timestamp: timestamp)
        }
    }
}

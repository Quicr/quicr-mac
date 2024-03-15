extension H264Publication {
    actor _Measurement: Measurement {
        var name: String = "VideoPublication"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var bytes: UInt64 = 0
        private var pixels: UInt64 = 0
        private var publishedFrames: UInt64 = 0
        private var capturedFrames: UInt64 = 0
        private var dropped: UInt64 = 0
        private var captureDelay: Double = 0
        private var publishDelay: Double = 0

        init(namespace: QuicrNamespace) {
            tags["namespace"] = namespace
        }

        func sentBytes(sent: UInt64, timestamp: Date?) {
            self.bytes += sent
            record(field: "sentBytes", value: self.bytes as AnyObject, timestamp: timestamp)
        }

        func sentPixels(sent: UInt64, timestamp: Date?) {
            self.pixels += sent
            record(field: "sentPixels", value: self.pixels as AnyObject, timestamp: timestamp)
        }

        func droppedFrame(timestamp: Date?) {
            self.dropped += 1
            record(field: "droppedFrames", value: self.dropped as AnyObject, timestamp: timestamp)
        }

        func publishedFrame(timestamp: Date?) {
            self.publishedFrames += 1
            record(field: "publishedFrames", value: self.publishedFrames as AnyObject, timestamp: timestamp)
        }

        func capturedFrame(timestamp: Date?) {
            self.capturedFrames += 1
            record(field: "capturedFrames", value: self.capturedFrames as AnyObject, timestamp: timestamp)
        }

        func captureDelay(delayMs: Double, timestamp: Date?) {
            record(field: "captureDelay", value: delayMs as AnyObject, timestamp: timestamp)
        }

        func publishDelay(delayMs: Double, timestamp: Date?) {
            record(field: "publishDelay", value: delayMs as AnyObject, timestamp: timestamp)
        }
    }
}

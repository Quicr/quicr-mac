extension H264Publication {
    actor _Measurement: Measurement {
        let id = UUID()
        var name: String = "VideoPublication"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        private var bytes: UInt64 = 0
        private var pixels: UInt64 = 0
        private var publishedFrames: UInt64 = 0
        private var capturedFrames: UInt64 = 0
        private var dropped: UInt64 = 0

        init(namespace: QuicrNamespace) {
            tags["namespace"] = namespace
        }

        func sentFrame(bytes: UInt64, timestamp: TimeInterval, at: Date?) {
            self.publishedFrames += 1
            self.bytes += bytes
            record(field: "sentBytes", value: self.bytes as AnyObject, timestamp: at)
            record(field: "publishedFrames", value: self.publishedFrames as AnyObject, timestamp: at)
            if let at = at {
                record(field: "timestamp", value: timestamp as AnyObject, timestamp: at)
            }
        }

        func sentPixels(sent: UInt64, timestamp: Date?) {
            self.pixels += sent
            record(field: "sentPixels", value: self.pixels as AnyObject, timestamp: timestamp)
        }

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

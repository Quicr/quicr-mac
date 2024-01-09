extension VideoHandler {
    actor _Measurement: Measurement {
        var name: String = "VideoHandler"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0
        private var decoded: UInt64 = 0

        init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
            tags["namespace"] = namespace
            Task(priority: .utility) {
                await submitter.register(measurement: self)
            }
        }

        func receivedFrame(timestamp: Date?) {
            self.frames += 1
            record(field: "receivedFrames", value: self.frames as AnyObject, timestamp: timestamp)
        }

        func decodedFrame(timestamp: Date?) {
            self.decoded += 1
            record(field: "decodedFrames", value: self.decoded as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: Int, timestamp: Date?) {
            self.bytes += UInt64(received)
            record(field: "receivedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
        }

        func receiveDelta(delta: Double, timestamp: Date?) {
            record(field: "receiveDelta", value: delta as AnyObject, timestamp: timestamp)
        }

        func decodeDelta(delta: Double, timestamp: Date?) {
            record(field: "decodeDelta", value: delta as AnyObject, timestamp: timestamp)
        }
    }
}
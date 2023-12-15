extension VideoJitterBuffer {
    actor _Measurement: Measurement {
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
            guard depth.isFinite,
                  depth.truncatingRemainder(dividingBy: 1) != 0 else {
                return
            }
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
}

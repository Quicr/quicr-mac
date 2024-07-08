extension VideoHandler {
    actor VideoHandlerMeasurement: QuicrMeasurementHandler {
        let id = UUID()
        let measurement: QuicrMeasurement

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0
        private var decoded: UInt64 = 0

        init(namespace: QuicrNamespace) {
            measurement = .init("VideoHandler")
            measurement.attributes.append(.init(name: "namespace", type: "string", value: namespace))
        }
        
        func receivedFrame(timestamp: Date?, idr: Bool) {
            self.frames += 1

            measurement.tag(attr: .init(name: "idr", type: "bool", value: "\(idr)"))
            measurement.record(field: "receivedFrames", value: self.frames as AnyObject, timestamp: timestamp)
        }

        func age(age: TimeInterval, timestamp: Date) {
            measurement.record(field: "age", value: age as AnyObject, timestamp: timestamp)
        }

        func decodedFrame(timestamp: Date?) {
            self.decoded += 1
            measurement.record(field: "decodedFrames", value: self.decoded as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: Int, timestamp: Date?) {
            self.bytes += UInt64(received)
            measurement.record(field: "receivedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
        }

        func enqueuedFrame(frameTimestamp: TimeInterval, metricsTimestamp: Date) {
            measurement.record(field: "enqueueTimestamp", value: frameTimestamp as AnyObject, timestamp: metricsTimestamp)
        }
    }
}

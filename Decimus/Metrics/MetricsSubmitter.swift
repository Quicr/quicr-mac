protocol MetricsSubmitter: Actor {
    func register(measurement: Measurement)
    func unregister(id: UUID)
    func submit() async
}

enum MetricsSubmitterType: String, Identifiable, CaseIterable {
    var id: Self {
        return self
    }

    case pubSub
    case influx
}

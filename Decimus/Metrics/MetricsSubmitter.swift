protocol MetricsSubmitter: Actor {
    func register(measurement: Measurement)
    func unregister(id: UUID)
    func submit() async
}

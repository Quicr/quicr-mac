protocol MetricsSubmitter: Actor {
    func register(measurement: Measurement)
    func submit() async
}

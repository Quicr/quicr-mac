protocol MetricsSubmitter: Actor {
    func register(measurement: Measurement)
}

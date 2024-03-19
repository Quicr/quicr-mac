actor MockSubmitter: MetricsSubmitter {
    func register(measurement: Measurement) { }
    func unregister(id: UUID) {}
    func submit() { }
}

actor MockSubmitter: MetricsSubmitter {
    func register(measurement: Measurement) { }
    func unregister(id: NSUUID) {}
    func submit() { }
}

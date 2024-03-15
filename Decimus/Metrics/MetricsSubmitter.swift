protocol MetricsSubmitter: Actor {
    func register(measurement: Measurement)
    func unregister(id: NSUUID)
    func submit() async
}

class MeasurementRegistration<Metric> where Metric: Measurement {
    let measurement: Metric
    private let submitter: MetricsSubmitter
    private let registration: Task<Void, Never>

    init(measurement: Metric, submitter: MetricsSubmitter) {
        self.measurement = measurement
        self.submitter = submitter
        self.registration = Task(priority: .utility) {
            await submitter.register(measurement: measurement)
        }
    }

    deinit {
        let registration = self.registration
        let submitter = self.submitter
        let id = self.measurement.id
        Task(priority: .utility) {
            await registration.value
            await submitter.unregister(id: id)
        }
    }
}

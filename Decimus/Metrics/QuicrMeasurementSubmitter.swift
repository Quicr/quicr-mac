import InfluxDBSwift
import Foundation
import os

actor QuicrMeasurementsSubmitter: MetricsSubmitter {
    private class WeakMeasurement {
        weak var measurement: (any Measurement)?
        let id: UUID
        init (_ measurement: any Measurement) {
            self.measurement = measurement
            self.id = measurement.id
        }
    }

    private static let logger = DecimusLogger(InfluxMetricsSubmitter.self)

    private weak var publisher: CallController?
    private var measurements: [UUID: WeakMeasurement] = [:]
    private let tags: [String: String]

    init(tags: [String: String]) {
        self.tags = tags
    }

    func setPublisher(publisher: CallController?) {
        self.publisher = publisher
    }

    func register(measurement: Measurement) {
        let updated = self.measurements.updateValue(.init(measurement), forKey: measurement.id)
        assert(updated == nil)
        guard updated == nil else {
            Self.logger.error("Shouldn't call register for existing measurement: \(measurement)")
            return
        }
    }

    func unregister(id: UUID) {
        let removed = self.measurements.removeValue(forKey: id)
        assert(removed != nil)
        guard removed != nil else {
            Self.logger.error("Shouldn't call unregister for non-existing ID: \(id)")
            return
        }
    }

    func submit() async {
        var toRemove: [UUID] = []
        for pair in self.measurements {
            let weakMeasurement = pair.value
            guard let measurement = weakMeasurement.measurement else {
                Self.logger.warning("Removing dead measurement")
                toRemove.append(weakMeasurement.id)
                continue
            }

            do {
                if let publisher = self.publisher {
                    let measurements = try await measurement.toQuicrMeasurements()
                    for qmeasure in measurements {
                        for (key, value) in tags {
                            qmeasure.tag(key, value: value)
                        }

                        publisher.publishMeasurement(measurement: qmeasure)
                    }
                }
            } catch {
                Self.logger.error("Failed to publish measurement")
            }
        }

        // Clean up dead weak references.
        for id in toRemove {
            self.measurements.removeValue(forKey: id)
        }
    }
}

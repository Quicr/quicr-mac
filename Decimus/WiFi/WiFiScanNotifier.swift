// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

protocol WiFiScanNotifier {
    func registerScanNotifier()
}

class MockWiFiScanNotifier: WiFiScanNotifier {
    func registerScanNotifier() {
        fatalError()
    }
}

#if canImport(CoreWLAN) && os(macOS)
import CoreWLAN

class CoreWLANWiFiScanNotifier: WiFiScanNotifier, CWEventDelegate {

    private let client = CWWiFiClient.shared()
    private let measurement: WiFiCacheEventMeasurement

    init(submitter: MetricsSubmitter) throws {
        try self.client.startMonitoringEvent(with: .scanCacheUpdated)
        let measurement = WiFiCacheEventMeasurement()
        submitter.register(measurement: measurement)
        self.measurement = measurement
        self.client.delegate = self
    }

    func registerScanNotifier() {

    }

    func scanCacheUpdatedForWiFiInterface(withName interfaceName: String) {
        self.measurement.updated(timestamp: Date.now)
    }
}

final class WiFiCacheEventMeasurement: MetricsMeasurement {
    let storage = MeasurementStorage()
    let name = "WiFi Scan"
    let tags: [String: String] = [:]

    func updated(timestamp: Date) {
        self.record(field: "Updated", value: 1, timestamp: timestamp)
    }
}

#endif

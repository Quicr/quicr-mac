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
    private let measurement: MeasurementRegistration<WiFiCacheEventMeasurement>

    init(submitter: MetricsSubmitter) throws {
        try self.client.startMonitoringEvent(with: .scanCacheUpdated)
        self.measurement = .init(measurement: .init(), submitter: submitter)
        self.client.delegate = self
    }

    func registerScanNotifier() {

    }

    func scanCacheUpdatedForWiFiInterface(withName interfaceName: String) {
        let now = Date.now
        Task(priority: .utility) {
            await self.measurement.measurement.updated(timestamp: now)
        }
    }
}

actor WiFiCacheEventMeasurement: Measurement {
    let id = UUID()
    var name: String = "WiFi Scan"
    var fields = Fields()
    var tags: [String: String] = [:]

    func updated(timestamp: Date) {
        self.record(field: "Updated", value: 1, timestamp: timestamp)
    }
}

#endif

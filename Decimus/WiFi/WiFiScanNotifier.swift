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

    init() throws {
        try self.client.startMonitoringEvent(with: .scanCacheUpdated)
        self.client.delegate = self
    }

    func registerScanNotifier() {

    }

    func scanCacheUpdatedForWiFiInterface(withName interfaceName: String) {
        print("*****Cached updated with: \(interfaceName)")
    }

}

#endif

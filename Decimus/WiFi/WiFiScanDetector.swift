// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Prediction result.
struct Prediction {
    /// Time until next scan.
    let timeToScan: TimeInterval?
    /// Predicted max inter-object interval during the spike.
    let predictedMagnitude: TimeInterval
    /// Predicted length of the spike event.
    let predictedLength: TimeInterval
    /// ID of the spike for tracking.
    let spikeId: Int
}

protocol WiFiScanDetector {
    func registerNotifyCallback(_ callback: @escaping () -> Void) -> Int
    func removeNotifyCallback(token: Int)
    func addIntervalMeasurement(interval: TimeInterval, identifier: String, timestamp: Date)
    func predictNextScan(from: Date) -> Prediction
}

class MockWiFiScanDetector: WiFiScanDetector {
    func registerNotifyCallback(_ callback: @escaping () -> Void) -> Int { 0 }
    func removeNotifyCallback(token: Int) {}
    func addIntervalMeasurement(interval: TimeInterval, identifier: String, timestamp: Date) {}
    func predictNextScan(from: Date) -> Prediction { .init(timeToScan: nil,
                                                           predictedMagnitude: 0,
                                                           predictedLength: 0,
                                                           spikeId: 0) }
}

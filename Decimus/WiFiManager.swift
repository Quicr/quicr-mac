import Foundation
import Network
import NetworkExtension
import CoreLocation

enum WiFiError: Error {
    case nonWiFi
    case noWifi
}

extension WiFiError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonWiFi:
            return "Current network not WiFi"
        case .noWifi:
            return "No WiFi network available"
        }
    }
}

class WiFiManager: NSObject, CLLocationManagerDelegate {
    private static let logger = DecimusLogger(WiFiManager.self)
    private var task: Task<(), Never>?
    private var measurement: _Measurement?
    private let queue = DispatchQueue(label: "com.cisco.Decimus.WiFiManager")
    private var currentHotspotNetwork: NEHotspotNetwork?
    private let submitter: MetricsSubmitter
    
    init(submitter: MetricsSubmitter) throws {
        self.submitter = submitter
        super.init()

        // Need CoreLocation.
        let location = CLLocationManager()
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.delegate = self
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        location.startUpdatingLocation()
        
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.start(queue: self.queue)

        // Ongoing monitoring.
        monitor.pathUpdateHandler = { path in
            Self.logger.warning("Path update", alert: true)
            guard path.usesInterfaceType(.wifi) else {
                Self.logger.warning("Skipping network monitoring as not WiFi", alert: true)
                return
            }
            NEHotspotNetwork.fetchCurrent { [weak self] network in
                Self.logger.warning("Got current: \(network)", alert: true)
                guard let self = self else { return }
                self.currentHotspotNetwork = network
                if self.task == nil {
                    startTask()
                }
            }
        }
        
        // First check.
        if monitor.currentPath.usesInterfaceType(.wifi) {
            Self.logger.warning("Got a wifi path: \(monitor.currentPath)", alert: true)
            Task(priority: .utility) {
                self.currentHotspotNetwork = await NEHotspotNetwork.fetchCurrent()
                Self.logger.warning("Current network: \(self.currentHotspotNetwork)")
                if self.task == nil {
                    startTask()
                }
            }
        } else {
            Self.logger.warning("Skipping network monitoring as not WiFi", alert: true)
        }
    }
    
    deinit {
        Self.logger.warning("Bye WiFi manager", alert: true)
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
    
    private func startTask() {
        Self.logger.warning("Starting task", alert: true)
        guard self.task == nil else { return }
        self.task = .init(priority: .utility) {
            if self.measurement == nil {
                self.measurement = await .init(submitter: self.submitter)
            }
            while !Task.isCancelled {
                if let network = self.currentHotspotNetwork {
                    let currentStrength = network.signalStrength
                    Self.logger.warning("Strength: \(currentStrength)", alert: true)
                    if let measurement = self.measurement {
                        await measurement.recordSignalStrength(value: currentStrength, timestamp: Date.now)
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

extension WiFiManager {
    actor _Measurement: Measurement {
        var name: String = "WiFiManager"
        var fields: [Date? : [String : AnyObject]] = [:]
        var tags: [String : String] = [:]

        init(submitter: MetricsSubmitter) async {
            await submitter.register(measurement: self)
        }

        func recordSignalStrength(value: Double, timestamp: Date) {
            record(field: "signalStrength", value: value as AnyObject, timestamp: timestamp)
        }
    }
}

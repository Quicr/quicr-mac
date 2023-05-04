import Foundation

struct ManifestServerConfig {
    let url: String
}

class ManifestController {
    private let url: String

    init(url: String) {
        self.url = url
    }

    init(config: ManifestServerConfig) {
        self.url = config.url
    }

    func requestManifest() {
        guard let url = URL(string: "\(url)/manifest") else { return }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data {
                
            }
            else if let error = error {
                print("[ManifestController] Failed to request manifest: \(error)")
            }
        }

        task.resume()
    }

    func updateManifest() {

    }

    func sendCapabilities() {

    }
}

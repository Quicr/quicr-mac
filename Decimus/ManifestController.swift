import Foundation

struct ManifestServerConfig {
    let url: String
    let port: Int
}

class ManifestController {
    static let shared = ManifestController()

    private var components: URLComponents = .init()
    private var mutex: DispatchSemaphore = .init(value: 0)

    func setServer(url: String) {
        self.components = URLComponents()
        self.components.scheme = "http"
        self.components.host = url
        self.components.port = 8080
    }

    func setServer(config: ManifestServerConfig) {
        self.components = URLComponents()
        self.components.scheme = "http"
        self.components.host = config.url
        self.components.port = config.port
    }

    private func makeRequest(method: String, components: URLComponents) -> URLRequest {
        guard let url = URL(string: components.string!) else {
            fatalError("[ManifestController] Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        return request
    }

    private func sendRequest(_ request: URLRequest, callback: @escaping (Data) -> Void) {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { self.mutex.signal() }

            if let error = error {
                print("[ManifestController] Failed to send request: \(error)")
                return
            }

            if let response = response as? HTTPURLResponse {
                print("[ManifestController] Got HTTP response with status code: \(response.statusCode)")
            }

            if let data = data {
                callback(data)
            }
        }
        task.resume()
        mutex.wait()
    }

    func getConferences() {
        var url = components
        url.path = "/conferences"

        let request = makeRequest(method: "GET", components: url)
        sendRequest(request) { data in
            print(data.prettyPrintedJSONString!)
        }
    }

    func getManifest(confId: UInt32, email: String) -> String {
        var url = components
        url.path = "/conferences/\(confId)/manifest"
        url.queryItems = [
            URLQueryItem(name: "email", value: email)
        ]

        var manifest: String = ""
        let request = makeRequest(method: "GET", components: url)
        sendRequest(request) { data in
            guard let json = data.prettyPrintedJSONString else { return }
            manifest = json as String
        }

        return manifest
    }

    func updateManifest() {

    }

    func sendCapabilities() {

    }
}

extension Data {
    var json: [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: self, options: []) as? [String: Any]
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    var prettyPrintedJSONString: NSString? {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: self, options: []),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject,
                                                       options: [.prettyPrinted]),
              let prettyJSON = NSString(data: data, encoding: String.Encoding.utf8.rawValue) else {
                  return nil
               }

        return prettyJSON
    }
}

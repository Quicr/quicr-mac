import Foundation
import os

struct ManifestServerConfig: Codable {
    var scheme: String = "https"
    var url: String = "conf.quicr.ctgpoc.com"
    var port: Int = 411
}

class ManifestController {
    private static let logger = DecimusLogger(ManifestController.self)

    static let shared = ManifestController()

    private var components: URLComponents = .init()
    private var mutex: DispatchSemaphore = .init(value: 0)

    func setServer(config: ManifestServerConfig) {
        self.components = URLComponents()
        self.components.scheme = config.scheme
        self.components.host = config.url
        self.components.port = config.port
    }

    private func makeRequest(method: String, components: URLComponents) throws -> URLRequest {
        guard let url = URL(string: components.string!) else {
            throw "Invalid URL: \(components)"
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
                Self.logger.error("Failed to send request: \(error)")
                return
            }

            if let response = response as? HTTPURLResponse {
                Self.logger.info("Got HTTP response with status code: \(response.statusCode)")
            }

            if let data = data {
                callback(data)
            }
        }
        task.resume()
        mutex.wait()
    }

    func getUser(email: String) async throws -> User {
        var url = components
        url.path = "/users"

        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        let users = try decoder.decode([User].self, from: data)

        guard let user = users.first(where: { $0.email == email }) else {
            throw "No user found for \(email)"
        }

        return user
    }

    func getConferences(for id: String) async throws -> [Conference] {
        var url = components
        url.path = "/conferences"

        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        let conferences = try decoder.decode([Conference].self, from: data)

        return conferences.filter { $0.participants.contains(id) }
    }

    func getManifest(confId: UInt32, email: String) async throws -> Manifest {
        var url = components
        url.path = "/conferences/\(confId)/manifest"
        url.queryItems = [
            URLQueryItem(name: "email", value: email)
        ]

        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        return try decoder.decode(Manifest.self, from: data)
    }

    func updateManifest() {

    }

    func sendCapabilities() {

    }
}

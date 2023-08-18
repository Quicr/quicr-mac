import Foundation
import os

struct ManifestServerConfig: Codable {
    var scheme: String = "https"
    var url: String = "conf.quicr.ctgpoc.com"
    var port: Int = 411
}

class ManifestController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: ManifestController.self)
    )

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

    func getUser(email: String) async throws -> String {
        var url = components
        url.path = "/users"

        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
            throw "Failed to deserialize JSON: \(data)"
        }

        guard let user = try json.first(where: { user in
            guard let userEmail = user["email"] as? String else {
                throw "Missing user email"
            }
            return userEmail == email
        }) else {
            return ""
        }

        guard let userId = user["id"] as? String else {
            throw "Missing user id"
        }
        return userId
    }

    func getConferences(for id: String) async throws -> [UInt32: String] {
        var url = components
        url.path = "/conferences"

        var meetings: [UInt32: String] = [:]
        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
            throw "Failed to deserialize JSON: \(data)"
        }

        let conferences = try json.filter { conference in
            guard let participants = conference["participants"] as? [String] else { throw "Conference missing participants" }
            return participants.contains(id)
        }

        for conference in conferences {
            guard let id = conference["id"] as? UInt32 else { throw "Conference missing id" }
            guard let title = conference["title"] as? String else { throw "Conference missing title" }
            meetings[id] = title
        }

        return meetings
    }

    func getManifest(confId: UInt32, email: String) async throws -> String {
        var url = components
        url.path = "/conferences/\(confId)/manifest"
        url.queryItems = [
            URLQueryItem(name: "email", value: email)
        ]

        var manifest: String = ""
        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = data.prettyPrintedJSONString else { return "" }
        manifest = json as String

        return manifest
    }

    func updateManifest() {

    }

    func sendCapabilities() {

    }
}

extension Data {
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

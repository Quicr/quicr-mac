// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import os

/// Possible errors thrown by ``ManifestController``
enum ManifestControllerError: Error {
    case invalidURL(_ url: URL)
    case badState
}

/// Configuration object for ``ManifestController``.
struct ManifestServerConfig: Codable, Equatable {
    /// URL.
    var url: URL = .init(string: "https://conf.quicr.ctgpoc.com:411")!
    /// Which manifest configuration to query against.
    var config: String = "testing"
}

/// Fetches and parses manifest/conference information from a server.
class ManifestController {
    private static let logger = DecimusLogger(ManifestController.self)

    private let components: URLComponents
    private var currentConfig: String = ""

    init(_ config: ManifestServerConfig) throws {
        guard let components = URLComponents(url: config.url, resolvingAgainstBaseURL: false) else {
            throw ManifestControllerError.invalidURL(config.url)
        }
        self.components = components
        self.currentConfig = config.config
    }

    /// Get the available configurations.
    /// - Returns: Array of available configurations.
    func getConfigs() async throws -> [Config] {
        var url = components
        url.path = "/configs"
        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        let configs = try decoder.decode([Config].self, from: data)

        guard configs.count > 0 else {
            throw "No configs found."
        }

        return configs
    }

    /// Get a user's details from their email.
    /// - Parameter email: User's email.
    func getUser(email: String) async throws -> User {
        var url = components
        url.path = "/users"

        url.queryItems = [
            URLQueryItem(name: "configProfile", value: self.currentConfig),
            URLQueryItem(name: "email", value: "\(String(describing: email))")
        ]

        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        let users = try decoder.decode([User].self, from: data)
        guard let user = users.first(where: { $0.email == email }) else {
            throw "No user found for \(email)"
        }

        return user
    }

    /// Get the list of available conferences for the given user.
    /// - Parameter email: Target user's email address.
    /// - Returns: List of conferences this user can join.
    func getConferences(for email: String) async throws -> [Conference] {
        var url = components
        url.path = "/conferences"

        url.queryItems = [
            URLQueryItem(name: "configProfile", value: self.currentConfig),
            URLQueryItem(name: "email", value: "\(String(describing: email))")
        ]

        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        let conferences = try decoder.decode([Conference].self, from: data)
        return conferences
    }

    /// Get the MoQ manifest for this user/conference combination.
    /// - Parameter confId: Conference ID to query.
    /// - Parameter email: Email of user querying the conference.
    /// - Returns: The manifest.
    func getManifest(confId: UInt32, email: String) async throws -> Manifest {
        var url = components
        url.path = "/conferences/\(confId)/manifest"
        url.queryItems = [
            URLQueryItem(name: "configProfile", value: self.currentConfig),
            URLQueryItem(name: "email", value: email)
        ]

        let request = try makeRequest(method: "GET", components: url)
        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        return try decoder.decode(Manifest.self, from: data)
    }

    private func makeRequest(method: String, components: URLComponents) throws -> URLRequest {
        guard let componentString = components.string,
              let url = URL(string: componentString) else {
            assert(false) // We should never be in this position.
            throw ManifestControllerError.badState
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        return request
    }
}

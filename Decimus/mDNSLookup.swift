// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Network

enum MDNSError: Error {
    case error(NWError)
    case cancelled
    case unknown
    case badAddress
    case failed
}

class MDNSLookup {
    private let logger = DecimusLogger(MDNSLookup.self)
    private var continuation: CheckedContinuation<Set<NWBrowser.Result>, Error>?
    private let type: String
    init(_ type: String) {
        self.type = type
    }

    func lookup() async throws -> Set<NWBrowser.Result> {
        let browser = NWBrowser(for: .bonjour(type: self.type, domain: nil), using: .init())
        return try await withCheckedThrowingContinuation(function: "MDNS") { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                continuation.resume(returning: results)
                browser.cancel()
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    continuation.resume(throwing: MDNSError.error(error))
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .utility))
        }
    }

    func resolveHostname(_ result: NWBrowser.Result) async throws -> (String, UInt16) {
        let connection = NWConnection(to: result.endpoint, using: .udp)
        return try await withCheckedThrowingContinuation(function: "RESOLVE") { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let endpoint = connection.currentPath?.remoteEndpoint,
                          case let .hostPort(host, port) = endpoint else {
                        continuation.resume(throwing: MDNSError.failed)
                        return
                    }
                    switch host {
                    case .name(let name, _):
                        continuation.resume(returning: (name, port.rawValue))
                    case .ipv4(let ipv4):
                        guard let address = "\(ipv4)".split(separator: "%").first else {
                            continuation.resume(throwing: MDNSError.badAddress)
                            return
                        }
                        continuation.resume(returning: (.init(address), port.rawValue))
                    case .ipv6(let ipv6):
                        guard let address = "\(ipv6)".split(separator: "%").first else {
                            continuation.resume(throwing: MDNSError.badAddress)
                            return
                        }
                        continuation.resume(returning: (.init(address), port.rawValue))
                    @unknown default:
                        continuation.resume(throwing: MDNSError.unknown)
                    }
                case .failed(let error):
                    continuation.resume(throwing: MDNSError.error(error))
                default:
                    self.logger.debug("\(state)")
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }
}

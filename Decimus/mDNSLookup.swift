// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Network

enum MDNSError: Error {
    case error(NWError)
    case unknown
    case badAddress
    case failed
}

struct MDNSLookup: Sendable {
    private let type: String
    init(_ type: String) {
        self.type = type
    }

    func lookup() async throws -> Set<NWBrowser.Result> {
        let browser = NWBrowser(for: .bonjour(type: self.type, domain: nil), using: .init())
        return try await Self.firstResult { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    continuation.finish(throwing: MDNSError.error(error))
                case .cancelled:
                    continuation.finish(throwing: CancellationError())
                default:
                    break
                }
            }
            browser.start(queue: .global(qos: .utility))
        } stop: {
            browser.browseResultsChangedHandler = nil
            browser.stateUpdateHandler = nil
            browser.cancel()
        }
    }

    func resolveHostname(_ result: NWBrowser.Result) async throws -> (String, UInt16) {
        let connection = NWConnection(to: result.endpoint, using: .udp)
        return try await Self.firstResult { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let endpoint = connection.currentPath?.remoteEndpoint,
                          case let .hostPort(host, port) = endpoint else {
                        continuation.finish(throwing: MDNSError.failed)
                        return
                    }
                    switch host {
                    case .name(let name, _):
                        continuation.yield((name, port.rawValue))
                    case .ipv4(let ipv4):
                        guard let address = "\(ipv4)".split(separator: "%").first else {
                            continuation.finish(throwing: MDNSError.badAddress)
                            return
                        }
                        continuation.yield((.init(address), port.rawValue))
                    case .ipv6(let ipv6):
                        guard let address = "\(ipv6)".split(separator: "%").first else {
                            continuation.finish(throwing: MDNSError.badAddress)
                            return
                        }
                        continuation.yield((.init(address), port.rawValue))
                    @unknown default:
                        continuation.finish(throwing: MDNSError.unknown)
                    }
                case .failed(let error):
                    continuation.finish(throwing: MDNSError.error(error))
                case .cancelled:
                    continuation.finish(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        } stop: {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    static func firstResult<Value: Sendable>(
        start: @Sendable (AsyncThrowingStream<Value, Error>.Continuation) -> Void,
        stop: @escaping @Sendable () -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<Value, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        continuation.onTermination = { _ in stop() }
        defer { continuation.finish() }
        start(continuation)
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        guard let value else { throw MDNSError.failed }
        return value
    }
}

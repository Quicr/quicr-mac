// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Darwin
import Foundation
import Network

/// Local address + interface
struct NetworkPathAddress: Equatable, Sendable {
    /// Native address.
    let address: sockaddr_storage

    /// Interface.
    let interfaceIndex: UInt32

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.interfaceIndex == rhs.interfaceIndex,
              lhs.address.ss_len == rhs.address.ss_len else { return false }
        return withUnsafeBytes(of: lhs.address) { left in
            withUnsafeBytes(of: rhs.address) { right in
                left.prefix(Int(lhs.address.ss_len)).elementsEqual(right.prefix(Int(rhs.address.ss_len)))
            }
        }
    }

    /// Collects addresses from the first available interface for the given path.
    /// - Parameter path: The path to use.
    /// - Returns: Local address candidates, or an empty array.
    static func candidates(for path: NWPath) -> [Self] {
        guard path.status == .satisfied,
              let interface = path.availableInterfaces.first(where: { path.usesInterfaceType($0.type) }),
              interface.type != .loopback else { return [] }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return [] }
        defer { freeifaddrs(addresses) }
        var result: [Self] = []
        var scopedAddresses: [Self] = []
        var current = addresses
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface.name,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) {
                $0.copyBytes(from: UnsafeRawBufferPointer(start: address, count: Int(address.pointee.sa_len)))
            }
            let candidate = Self(address: storage, interfaceIndex: UInt32(interface.index))
            // Prefer unscoped addresses over link-local IPv6 addresses for the relay path.
            if family == AF_INET6,
               UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_scope_id != 0 {
                scopedAddresses.append(candidate)
            } else {
                result.append(candidate)
            }
        }
        return result + scopedAddresses
    }
}

/// Path changes.
struct NetworkPathMigrationState: Sendable {
    /// The previous address, if any.
    private var previous: [NetworkPathAddress]?

    /// Record a new path and if we should attempt to migrate.
    /// - Parameter addresses: New addresses.
    /// - Returns: `true` if we observe a change.
    mutating func update(_ addresses: [NetworkPathAddress]) -> Bool {
        defer { self.previous = addresses }
        guard let previous else { return false }
        return !addresses.isEmpty && addresses != previous
    }
}

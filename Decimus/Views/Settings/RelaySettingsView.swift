// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct RelaySettingsView: View {
    static let defaultsKey = "relayConfig1"
    private let logger = DecimusLogger(RelaySettingsView.self)

    @AppStorage(Self.defaultsKey)
    private var relayConfig: AppStorageWrapper<RelayConfig> = .init(value: .init())

    @State private var dnsInProgress = false
    @State private var dnsMessage: String?

    var body: some View {
        Section("Relay") {
            VStack {
                HStack {
                    LabeledToggle("Use mDNS", isOn: self.$relayConfig.value.usemDNS)
                    if self.dnsInProgress {
                        ProgressView()
                    }
                }
                if self.relayConfig.value.usemDNS,
                   let dnsMessage = self.dnsMessage {
                    Text(dnsMessage).foregroundStyle(.red).font(.footnote)
                }
            }

            LabeledContent("Address") {
                TextField("relay_address", text: $relayConfig.value.address, prompt: Text("moq://localhost:443"))
                    #if canImport(UIKit)
                    .keyboardType(.URL)
                    #endif
                    .labelsHidden()
            }
        }
        .formStyle(.columns)
        .task {
            await self.mdnsRefresh()
        }
        .onChange(of: self.relayConfig.value.usemDNS) {
            Task { await self.mdnsRefresh() }
        }
    }

    private func mdnsRefresh() async {
        guard self.relayConfig.value.usemDNS else {
            self.dnsInProgress = false
            return
        }
        self.dnsInProgress = true
        defer { self.dnsInProgress = false }
        do {
            guard let lookup = try await self.mdnsLookup(self.relayConfig.value.mDNSType) else {
                self.dnsMessage = "mDNS had no results"
                return
            }
            self.dnsMessage = nil
            self.relayConfig.value.address = "moq://\(lookup.0):\(lookup.1)"
        } catch {
            self.dnsMessage = "mDNS Failure: \(error.localizedDescription)"
        }
    }

    private func mdnsLookup(_ type: String) async throws -> (String, UInt16)? {
        let lookerUpper = MDNSLookup(type)
        let result = try await lookerUpper.lookup()
        guard let result = result.first else { return nil }
        return try await lookerUpper.resolveHostname(result)
    }
}

struct RelaySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            RelaySettingsView()
        }
    }
}

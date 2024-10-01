// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct TransportConfigSettings: View {
    @Binding var quicCwinMinimumKiB: UInt64
    @Binding var timeQueueTTL: Int
    @Binding var chunkSize: UInt32
    @Binding var useResetWaitCC: Bool
    @Binding var useBBR: Bool
    @Binding var quicrLogs: Bool
    @Binding var enableQlog: Bool
    @Binding var quicPriorityLimit: UInt8
    private let minWindowKiB = 2
    private let maxWindowKiB = 4096

    var body: some View {
        #if !os(tvOS)
        VStack {
            HStack {
                Stepper {
                    Text("QUIC CWIN: \(self.quicCwinMinimumKiB) KiB")
                } onIncrement: {
                    let new = self.quicCwinMinimumKiB * 2
                    guard new <= maxWindowKiB else { return }
                    self.quicCwinMinimumKiB = new
                } onDecrement: {
                    let new = self.quicCwinMinimumKiB / 2
                    guard new >= minWindowKiB else { return }
                    self.quicCwinMinimumKiB = new
                }
            }
        }
        #endif
        LabeledToggle("Use Reset and Wait",
                      isOn: self.$useResetWaitCC)
        LabeledToggle("Use BBR",
                      isOn: self.$useBBR)
        LabeledContent("Time Queue RX Size") {
            NumberView(value: self.$timeQueueTTL,
                       formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                       name: "Size")
        }
        LabeledContent("Chunk Size") {
            NumberView(value: self.$chunkSize,
                       formatStyle: IntegerFormatStyle<UInt32>.number.grouping(.never),
                       name: "Size")
        }
        LabeledContent("Limit Bypass Priority >= value") {
            NumberView(value: self.$quicPriorityLimit,
                       formatStyle: IntegerFormatStyle<UInt8>.number.grouping(.never),
                       name: "Priority")
        }
        LabeledToggle("Capture QUICR logs",
                      isOn: self.$quicrLogs)
        LabeledToggle("Enable QLOG",
                      isOn: self.$enableQlog)
    }
}

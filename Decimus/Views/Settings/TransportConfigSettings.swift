import SwiftUI

struct TransportConfigSettings: View {
    @Binding var quicCwinMinimumKiB: UInt64
    @Binding var timeQueueTTL: Int
    @Binding var chunkSize: UInt32
    @Binding var UseResetWaitCC: Bool
    @Binding var UseBBR: Bool
    @Binding var quicrLogs: Bool
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
        HStack {
            Text("Use Reset and Wait")
            Toggle(isOn: self.$UseResetWaitCC) {}
        }
        HStack {
            Text("Use BBR")
            Toggle(isOn: self.$UseBBR) {}
        }
        LabeledContent("Time Queue RX Size") {
            TextField("", value: self.$timeQueueTTL, format: .number)
        }
        LabeledContent("Chunk Size") {
            TextField("", value: self.$chunkSize, format: .number)
        }
        HStack {
            Text("Capture QUICR logs")
            Toggle(isOn: self.$quicrLogs) {}
        }
    }
}

import SwiftUI

struct TransportConfigSettings: View {
    @Binding var quicCwinMinimumKiB: UInt64
    @Binding var quicWifiShadowRttUs: TimeInterval
    @Binding var timeQueueTTL: Int
    @Binding var UseResetWaitCC: Bool
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
        LabeledContent("QUIC WiFi RTT") {
            TextField("", value: self.$quicWifiShadowRttUs, format: .number)
        }
        LabeledContent("Time Queue RX Size") {
            TextField("", value: self.$timeQueueTTL, format: .number)
        }
        
    }
}

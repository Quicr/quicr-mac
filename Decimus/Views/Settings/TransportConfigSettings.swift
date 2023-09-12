import SwiftUI

struct TransportConfigSettings: View {
    @Binding var quicCwinMinimumKiB: UInt64
    private let minWindowKiB = 2
    private let maxWindowKiB = 4096

    var body: some View {
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
}

#Preview {
    TransportConfigSettings(quicCwinMinimumKiB: .constant(128))
}

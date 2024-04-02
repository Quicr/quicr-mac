import SwiftUI

struct ConfigCallView: View {
    @State private var config: CallConfig?

    var body: some View {
        if config != nil {
            InCallView(config: config!) { config = nil }
#if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        } else {
            CallSetupView { self.config = $0 }
#if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }
}

struct ConfigCall_Previews: PreviewProvider {
    static var previews: some View {
        ConfigCallView()
    }
}

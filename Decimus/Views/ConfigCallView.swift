import SwiftUI

struct ConfigCallView: View {
    @State private var config: CallConfig?
    @StateObject private var errorWriter: ObservableError = .init()

    var body: some View {
        if config != nil {
            InCallView(errorWriter: errorWriter, config: config!) { config = nil }
                .environmentObject(errorWriter)
        } else {
            CallSetupView { self.config = $0 }
                .environmentObject(errorWriter)
        }
    }
}

struct ConfigCall_Previews: PreviewProvider {
    static var previews: some View {
        ConfigCallView()
    }
}

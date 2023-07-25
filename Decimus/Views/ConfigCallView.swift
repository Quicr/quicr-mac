import SwiftUI

struct ConfigCallView: View {
    @State private var config: CallConfig?
    @State private var errorWriter: ObservableError

    init(errorWriter: ObservableError, config: CallConfig? = nil) {
        self.config = config
        self.errorWriter = errorWriter
    }

    var body: some View {
        if config != nil {
            InCallView(config: config!, errorHandler: self.errorWriter) { config = nil }
        } else {
            CallSetupView(errorWriter: self.errorWriter) { self.config = $0 }
        }
    }
}

struct ConfigCall_Previews: PreviewProvider {
    static var previews: some View {
        ConfigCallView(errorWriter: ObservableError())
    }
}

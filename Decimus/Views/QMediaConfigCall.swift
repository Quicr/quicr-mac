import SwiftUI

struct QMediaConfigCall: View {

    @State private var inCall: Bool = false

    private let callback: ConfigCallback
    private let mode: ApplicationModeBase?

    init(mode: ApplicationModeBase?, callback: @escaping ConfigCallback) {
        self.callback = callback
        self.mode = mode
    }

    var body: some View {
        if inCall {
            // Show the call page.
            InCallView(mode: mode) {
                inCall = false
            }
        } else {
            // Show the call setup page.
            CallSetupView(joinCall)
        }
    }

    func joinCall(config: CallConfig) {
        inCall = true
        callback(config)
    }
}

struct QMediaConfigCall_Previews: PreviewProvider {
    static var previews: some View {
        QMediaConfigCall(mode: nil) { _ in }
    }
}

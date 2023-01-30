import SwiftUI

struct QMediaConfigCall: View {

    @State private var inCall: Bool = false

    private let callback: ConfigCallback

    init(callback: @escaping ConfigCallback) {
        self.callback = callback
    }

    var body: some View {
        if inCall {
            // Show the call page.
            InCallView {
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
        QMediaConfigCall(callback: { _ in })
    }
}

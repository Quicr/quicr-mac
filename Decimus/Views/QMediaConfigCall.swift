import SwiftUI

struct QMediaConfigCall: View {
    @State private var config: CallConfig?

    var body: some View {
        if config != nil {
            InCallView<QMediaPubSub>(config: config!) {
                config = nil
            }
        } else {
            CallSetupView(onJoin)
        }
    }

    func onJoin(config: CallConfig) {
        self.config = config
    }
}

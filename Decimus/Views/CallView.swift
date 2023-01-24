import SwiftUI

struct CallView: View {
    
    @State private var inCall: Bool = false
    
    var body: some View {
        if (inCall) {
            // Show the call page.
            InCallView {
                inCall = false
            }
        }
        else {
            // Show the call setup page.
            CallSetupView(joinCall)
        }
    }
    
    func joinCall(config: CallConfig) {
        inCall = true
    }
}

struct CallView_Previews: PreviewProvider {
    static var previews: some View {
        CallView()
    }
}

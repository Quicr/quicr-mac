import SwiftUI

struct SubscriptionPopover: View {
    @State private var switchingSets: [String] = []
    let controller: CallController

    var body: some View {
        Text("Alter Subscriptions")
            .font(.title)
            .onAppear {
                print("Running")
                self.switchingSets = self.controller.fetchSwitchingSets()
            }
            .padding()

        ForEach(self.switchingSets, id: \.self) { set in
            VStack {
                Text(set)
                    .font(.headline)
                ForEach(controller.fetchSubscriptions(sourceId: set), id: \.self) { subscription in
                    Button {
                        print("Stopping subscription now: \(subscription)")
                        self.controller.stopSubscription(subscription)
                        self.switchingSets = controller.fetchSwitchingSets()
                    } label: {
                        Text(subscription)
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }
            }
        }
    }
}

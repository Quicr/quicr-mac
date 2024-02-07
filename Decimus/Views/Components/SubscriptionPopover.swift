import SwiftUI

struct SubscriptionPopover: View {
    private class SwitchingSets: ObservableObject {
        private let controller: CallController
        @Published var sets: [String] = []

        init(controller: CallController) {
            self.controller = controller
        }

        func fetch() {
            self.sets = self.controller.fetchSwitchingSets()
        }
    }

    @StateObject private var switchingSets: SwitchingSets
    @State private var manifest: Manifest?
    @State private var urlEncoder: UrlEncoderGWObjC?
    private let controller: CallController

    init(controller: CallController) {
        self.controller = controller
        self._switchingSets = .init(wrappedValue: .init(controller: controller))
    }

    var body: some View {
        Text("Alter Subscriptions")
            .font(.title)
            .onAppear {
                self.switchingSets.fetch()
            }
            .padding()

        ScrollView {
            ForEach(self.$switchingSets.sets, id: \.self) { $set in
                VStack {
                    Text(manifest?.getSwitchingSet(sourceId: set)?.label ?? set)
                        .font(.headline)
                    ForEach(controller.fetchSubscriptions(sourceId: set), id: \.self) { subscription in
                        Button {
                            self.controller.stopSubscription(subscription)
                            self.switchingSets.fetch()
                        } label: {
                            if let manifest = self.manifest,
                               let urlEncoder = self.urlEncoder,
                               let profile = manifest.getSubscription(sourceId: set, namespace: subscription, encoder: urlEncoder) {
                                Text(profile.qualityProfile)
                            } else {
                                Text(subscription)
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                    }
                }
            }
        }
        .task {
            if let manifest = await self.controller.manifest.currentManifest {
                self.manifest = manifest
                self.urlEncoder = .init(manifest.urlTemplates)
            }
        }
    }
}

extension Manifest {
    func getSwitchingSet(sourceId: SourceIDType) -> ManifestSubscription? {
        for switchingSet in self.subscriptions where switchingSet.sourceID == sourceId {
            return switchingSet
        }
        return nil
    }

    func getSubscription(sourceId: SourceIDType, namespace: QuicrNamespace, encoder: UrlEncoderGWObjC) -> Profile? {
        guard let switchingSet = getSwitchingSet(sourceId: sourceId) else { return nil }
        for profile in switchingSet.profileSet.profiles {
            let encoded = encoder.encodeUrl(profile.namespaceURL)
            if namespace == encoded {
                return profile
            }
        }
        return nil
    }
}

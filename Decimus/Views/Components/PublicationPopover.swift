import SwiftUI

struct PublicationPopover: View {
    private class Publications: ObservableObject {
        private let controller: CallController
        @Published var publications: [PublicationReport] = []

        init(controller: CallController) {
            self.controller = controller
        }

        func fetch() {
            self.publications = self.controller.fetchPublications()
        }
    }

    @StateObject private var publications: Publications
    @State private var manifest: Manifest?
    @State private var urlEncoder: UrlEncoderGWObjC?
    @State private var toggleStates: [QuicrNamespace: Bool] = [:]
    private let controller: CallController

    init(controller: CallController) {
        self.controller = controller
        self._publications = .init(wrappedValue: .init(controller: controller))
    }

    private func updateToggles() {
        for publication in publications.publications {
            self.toggleStates[publication.quicrNamespace] = publication.state == .active
        }
    }

    private func makePublishStateBinding(_ namespace: QuicrNamespace) -> Binding<Bool> {
           return .init(
               get: { self.toggleStates[namespace, default: false] },
               set: { self.toggleStates[namespace] = $0 })
       }

    var body: some View {
        Text("Alter Publications")
            .font(.title)
            .onAppear {
                self.publications.fetch()
                self.updateToggles()
            }
            .padding()

        ScrollView {
            ForEach(self.publications.publications, id: \.self) { publication in
                Toggle(isOn: makePublishStateBinding(publication.quicrNamespace)) {
                    if let manifest = self.manifest,
                       let encoder = self.urlEncoder,
                       let profile = manifest.getPublication(namespace: publication.quicrNamespace, encoder: encoder) {
                        Text(profile.qualityProfile)
                    } else {
                        Text(publication.quicrNamespace)
                    }
                }
                .padding()
                .onChange(of: self.toggleStates[publication.quicrNamespace]!) {
                    self.controller.setPublicationState(publication.quicrNamespace, publicationState: $0 ? .active : .paused)
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
    func getPublication(namespace: QuicrNamespace, encoder: UrlEncoderGWObjC) -> Profile? {
        for publication in self.publications {
            for profile in publication.profileSet.profiles {
                let encoded = encoder.encodeUrl(profile.namespaceURL)
                if namespace == encoded {
                    return profile
                }
            }
        }
        return nil
    }
}

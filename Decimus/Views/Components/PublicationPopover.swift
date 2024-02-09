import SwiftUI

struct PublicationPopover: View {
    private class Publications: ObservableObject {
        private let controller: CallController
        @Published var publications: [QuicrNamespace] = []

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
    private let controller: CallController

    init(controller: CallController) {
        self.controller = controller
        self._publications = .init(wrappedValue: .init(controller: controller))
    }

    var body: some View {
        Text("Alter Publications")
            .font(.title)
            .onAppear {
                self.publications.fetch()
            }
            .padding()

        ScrollView {
            ForEach(self.publications.publications, id: \.self) { namespace in
                if let manifest = self.manifest,
                   let encoder = self.urlEncoder,
                   let publication = manifest.getPublication(namespace: namespace, encoder: encoder) {
                    Text(publication.qualityProfile)
                } else {
                    Text(namespace)
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

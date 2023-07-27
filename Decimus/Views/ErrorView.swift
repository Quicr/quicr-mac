import SwiftUI

@MainActor
class ObservableError: ObservableObject, ErrorWriter {
    struct StringError: Identifiable {
        let id = UUID()
        let message: String
    }

    @Published var messages: [StringError] = []
    nonisolated func writeError(_ message: String) {
        print("[Decimus Error] => \(message)")
        DispatchQueue.main.async {
            self.messages.append(.init(message: message))
       }
    }
}

struct ErrorView: View {
    @EnvironmentObject var errorHandler: ObservableError
    var body: some View {
        VStack {
            if !errorHandler.messages.isEmpty {
                Text("Errors:")
                    .font(.title)
                    .foregroundColor(.red)

                // Clear all.
                Button {
                    errorHandler.messages.removeAll()
                } label: {
                    Text("Clear Errors")
                }
                .buttonStyle(.borderedProminent)

                // Show the messages.
                ScrollView {
                    ForEach(errorHandler.messages) { message in
                        Text(message.message)
                            .padding()
                            .background(Color.red)
                    }
                }
            }
        }
    }
}

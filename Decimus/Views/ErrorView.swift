import SwiftUI
import os

@MainActor
class ObservableError: ObservableObject {
    struct StringError: Identifiable {
        let id = UUID()
        let message: String
    }

    static let shared = ObservableError()

    @Published var messages: [StringError] = []
    nonisolated func write(logger: Logger, _ message: String) {
        logger.error("\(message)")
        DispatchQueue.main.async {
            self.messages.append(.init(message: message))
        }
    }
}

struct ErrorView: View {
    var body: some View {
        VStack {
            if !ObservableError.shared.messages.isEmpty {
                Text("Errors:")
                    .font(.title)
                    .foregroundColor(.red)

                // Clear all.
                Button {
                    ObservableError.shared.messages.removeAll()
                } label: {
                    Text("Clear Errors")
                }
                .buttonStyle(.borderedProminent)

                // Show the messages.
                ScrollView {
                    ForEach(ObservableError.shared.messages) { message in
                        Text(message.message)
                            .padding()
                            .background(Color.red)
                    }
                }
            }
        }
    }
}

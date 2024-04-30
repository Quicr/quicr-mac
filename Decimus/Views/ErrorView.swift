import SwiftUI

private func getLogColour(_ level: DecimusLogger.LogLevel) -> Color {
    switch level {
    case .error, .critical:
        return .red
    case .warning:
        return .orange
    case .debug:
        return .pink
    default:
        return .blue
    }
}

struct AlertView: View {
    @StateObject var logger = DecimusLogger.shared

    var body: some View {
        VStack {
            if !logger.alerts.isEmpty {
                Text("Errors:")
                    .font(.title)
                    .foregroundColor(.red)

                // Clear all.
                Button {
                    logger.alerts.removeAll()
                } label: {
                    Text("Clear Errors")
                }
                .buttonStyle(.borderedProminent)

                // Show the messages.
                ScrollView {
                    ForEach(logger.alerts) { alert in
                        Text(alert.message)
                            .padding()
                            .background(getLogColour(alert.level))
                    }
                }
            }
        }
    }
}

import SwiftUI
import os

struct ErrorView: View {
    @StateObject var logger = DecimusLogger.shared
    @State var filters: [DecimusLogger.LogLevel] = []

    private let dateFormat = DateFormatter()

    init() {
//        dateFormat.dateFormat = "yyyy-mm-dd hh:mm:ss.SSS"
        dateFormat.dateFormat = "hh:mm:ss.SSS"
    }

    func getLogColour(_ level: DecimusLogger.LogLevel) -> Color {
        switch level {
        case .error, .fault:
            return .red
        case .warning:
            return .yellow
        case .debug:
            return .orange
        case .trace:
            return .cyan
        default:
            return .white
        }
    }

    func addOrRemoveFilters(_ filter: DecimusLogger.LogLevel) {
        guard let index = filters.firstIndex(of: filter) else {
            filters.append(filter)
            return
        }
        filters.remove(at: index)
    }

    func addOrRemoveFilters(_ filters: [DecimusLogger.LogLevel]) {
        for filter in filters {
            addOrRemoveFilters(filter)
        }
    }

    var body: some View {
        HStack {
            Button(action: { addOrRemoveFilters([.error, .fault]) }, label: {
                Image(systemName: "exclamationmark.octagon")
            })
            .symbolVariant(.fill)
            .foregroundStyle(.white, .red, .red)
            Button(action: { addOrRemoveFilters(.warning) }, label: {
                Image(systemName: "exclamationmark.triangle")
            })
            .symbolVariant(.fill)
            .foregroundStyle(.white, .yellow, .yellow)
            Button(action: { addOrRemoveFilters(.info) }, label: {
                Image(systemName: "exclamationmark")
            })
            .symbolVariant(.circle.fill)
            .foregroundStyle(.white, .blue, .blue)
            Button(action: { addOrRemoveFilters([.debug, .trace]) }, label: {
                Image(systemName: "ant")
            })
            .symbolVariant(.circle.fill)
            .foregroundStyle(.white, .orange, .orange)
            Button(action: { filters.removeAll() }, label: {
                Image(systemName: "xmark")
            })
        }
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                let logs = logger.logs.filter({ log in
                    filters.isEmpty || filters.contains(log.level)
                }).reversed()
                VStack(alignment: .leading) {
                    ForEach(logs) { log in
                        HStack {
                            Text("\(dateFormat.string(from: log.date))")
                                .foregroundColor(.gray)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("[\(log.category)]")
                                .foregroundColor(.blue)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(log.message)
                                .foregroundColor(getLogColour(log.level))
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ErrorView_Previews: PreviewProvider {
    static let logger = DecimusLogger(ErrorView_Previews.self)
    init() {
        Self.logger.error("I'm an error")
        Self.logger.warning("I'm a warning")
        Self.logger.info("I'm info")
        Self.logger.debug("I'm debug")
        Self.logger.trace("I'm a trace")
    }
    static var previews: some View {
        ErrorView()
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
                            .background(Color.red)
                    }
                }
            }
        }
    }
}

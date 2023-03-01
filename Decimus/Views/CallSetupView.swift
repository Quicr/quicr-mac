import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> Void

struct CallSetupView: View {

    @State private var address: String = ""
    @State private var port: UInt16 = 0

    private var configCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        configCallback = onJoin
    }

    var body: some View {
        Text("Real Time Media Client").font(.title)
        Form {
            Section(header: Text("Join a meeting")) {
                HStack {
                    TextField("Address", text: $address, prompt: Text("Server Address")).disableAutocorrection(true)
                    Divider()
                    Button(action: {
                        address = "127.0.0.1"
                        port = 1234
                    }, label: {
                        Text("localhost")
                    }).buttonStyle(.bordered)
                    Button(action: {
                        address = "relay.us-west-2.quicr.ctgpoc.com"
                        port = 33434
                    }, label: {
                        Text("AWS")
                    }).buttonStyle(.bordered)
                }.alignmentGuide(.listRowSeparatorLeading) { _ in
                    return 0
                }
                TextField("Port", value: $port, format: .number.grouping(.never), prompt: Text("Server Port"))
                Button(action: join) {
                    Label("Join", systemImage: "phone")
                }
            }
        }
    }

    func join() {
        configCallback(.init(address: address, port: port))
    }
}

struct CallSetupView_Previews: PreviewProvider {
    static var previews: some View {
        CallSetupView { _ in }
    }
}

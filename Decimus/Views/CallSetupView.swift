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
                TextField("Address", text: $address, prompt: Text("Server Address"))
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

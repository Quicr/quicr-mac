import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> Void

private struct LoginForm: View {
    private struct AddressPort: Hashable {
        var address: String
        var port: UInt16
        init(address: String, port: UInt16) {
            self.address = address
            self.port = port
        }
    }
    @State private var addressPort: AddressPort = .init(address: "", port: 0)
    @State private var connectionProtocol: QMedia.ProtocolType = QMedia.ProtocolType.QUIC

    private var joinMeetingCallback: ConfigCallback

    private let buttonColour = ActionButtonStyleConfig(background: .white, foreground: .black)

    init(_ onJoin: @escaping ConfigCallback) {
        joinMeetingCallback = onJoin
    }

    var body: some View {
        Form {
            // TODO: For Dev purposes, should be removed eventually
            Section {
                Picker(selection: $addressPort, label: Text("Protocol")) {
                    Text("localhost").tag(AddressPort(address: "127.0.0.1", port: 1234))
                    Text("AWS").tag(AddressPort(address: "relay.us-west-2.quicr.ctgpoc.com", port: 33435))
                    .font(Font.system(size: 19, weight: .semibold))
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                FormInput("Address", field: TextField("", text: $addressPort.address, prompt: Text("")))
                FormInput("Port", field: TextField("",
                                                   value: $addressPort.port,
                                                   format: .number.grouping(.never),
                                                   prompt: Text("")))
                Picker(selection: $connectionProtocol, label: Text("Protocol")) {
                    Text("UDP").tag(QMedia.ProtocolType.UDP)
                    Text("QUIC").tag(QMedia.ProtocolType.QUIC)
                }
                .pickerStyle(.segmented)

                ActionButton("Join Meeting",
                             font: Font.system(size: 19, weight: .semibold),
                             disabled: addressPort.address == "" || addressPort.port == 0,
                             styleConfig: buttonColour,
                             action: join)
                .frame(maxWidth: .infinity)
                .font(Font.system(size: 19, weight: .semibold))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .background(.clear)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
    }

    func join() {
        joinMeetingCallback(.init(address: addressPort.address,
                                  port: addressPort.port,
                                  connectionProtocol: connectionProtocol))
    }
}

struct CallSetupView: View {
    private var joinMeetingCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        joinMeetingCallback = onJoin
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image("RTMC-Background")
                    .resizable()
                    .scaledToFill()
                    .edgesIgnoringSafeArea(.all)
                    .frame(width: geo.size.width,
                           height: geo.size.height + 50, // see about getting rid of the 50
                           alignment: .center)
                VStack {
                    Image("RTMC-Icon").padding(-50)
                    Text("Real Time Media Client")
                        .font(.largeTitle)
                        .foregroundColor(.white)
                    Spacer(minLength: 25)
                    Text("Join a meeting")
                        .font(.title)
                        .foregroundColor(.white)
                    LoginForm(joinMeetingCallback)
                        .frame(maxWidth: 350)
                        .padding(.top, -30)
                }
            }
        }
    }
}

struct CallSetupView_Previews: PreviewProvider {
    static var previews: some View {
        CallSetupView { _ in }
    }
}

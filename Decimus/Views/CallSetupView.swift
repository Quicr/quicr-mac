import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> Void

private struct LoginForm: View {
    @State private var callConfig = CallConfig(address: "",
                                               port: 0,
                                               connectionProtocol: MediaClient.ProtocolType.QUIC)
    private var joinMeetingCallback: ConfigCallback

    private let buttonColour = ActionButtonStyleConfig(
        background: .white,
        foreground: .black
    )

    init(_ onJoin: @escaping ConfigCallback) {
        joinMeetingCallback = onJoin
    }

    var body: some View {
        Form {
            Section {
                RadioButtonGroup("Developer Relays",
                                 selection: $callConfig,
                                 labels: ["localhost", "AWS"],
                                 tags: [
                    .init(address: "127.0.0.1", port: 1234, connectionProtocol: callConfig.connectionProtocol),
                    .init(address: "relay.us-west-2.quicr.ctgpoc.com",
                          port: callConfig.connectionProtocol == MediaClient.ProtocolType.UDP ? 33434 : 33435,
                          connectionProtocol: callConfig.connectionProtocol)
                ])

                VStack(alignment: .leading) {
                    Text("Address")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField.init("address", text: $callConfig.address, prompt: Text(""))
                        .textFieldStyle(FormInputStyle())
                }
                VStack(alignment: .leading) {
                    Text("Port")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField.init("port",
                                   value: $callConfig.port,
                                   format: .number.grouping(.never),
                                   prompt: Text(""))
                        .textFieldStyle(FormInputStyle())
                }

                RadioButtonGroup("Protocol",
                                 selection: $callConfig.connectionProtocol,
                                 tags: MediaClient.ProtocolType.allCases)

                ActionButton("Join Meeting",
                             font: Font.system(size: 19, weight: .semibold),
                             disabled: callConfig.address == "" || callConfig.port == 0,
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
        joinMeetingCallback(callConfig)
    }
}

struct CallSetupView: View {
    private var joinMeetingCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        UIApplication.shared.isIdleTimerDisabled = false
        joinMeetingCallback = onJoin
    }

    var body: some View {
        ZStack {
            Image("RTMC-Background")
                .resizable()
                .scaledToFill()
                .edgesIgnoringSafeArea(.all)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                #if targetEnvironment(macCatalyst)
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .center)
                #else
                .frame(width: UIScreen.main.bounds.width,
                       height: UIScreen.main.bounds.height,
                       alignment: .center)
                #endif

            VStack {
                Image("RTMC-Icon")
                Text("Real Time Media Client")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.white)
                Spacer(minLength: 25)
                Text("Join a meeting")
                    .font(.title)
                    .foregroundColor(.white)
                LoginForm(joinMeetingCallback)
                    .frame(maxWidth: 350)
            }
        }
    }
}

struct CallSetupView_Previews: PreviewProvider {
    static var previews: some View {
        CallSetupView { _ in }
    }
}

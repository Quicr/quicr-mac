import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> Void

private let buttonColour = ActionButtonStyleConfig(
    background: .white,
    foreground: .black
)

private struct LoginForm: View {
    @AppStorage("email") private var email: String = ""
    @AppStorage("relayAddress") private var relayAddress: String = RelayURLs.usWest2.rawValue
    @State private var callConfig = CallConfig(address: "",
                                               port: relayConfigs[RelayURLs.usWest2]?[.QUIC] ?? 0,
                                               connectionProtocol: .QUIC)
    private var joinMeetingCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        joinMeetingCallback = onJoin
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Email")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("email", text: $email, prompt: Text("example@cisco.com"))
                        .textFieldStyle(FormInputStyle())
                }

                RadioButtonGroup("Protocol",
                                 selection: $callConfig,
                                 labels: ["UDP", "QUIC"],
                                 tags: [
                    .init(address: relayAddress,
                          port: getPort(.UDP),
                          connectionProtocol: .UDP,
                          email: email),
                    .init(address: relayAddress,
                          port: getPort(.QUIC),
                          connectionProtocol: .QUIC,
                          email: email)
                ])

                ActionButton("Join Meeting",
                             font: Font.system(size: 19, weight: .semibold),
                             disabled: callConfig.email == "" || callConfig.port == 0,
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
        .frame(maxHeight: 450)
        .scrollDisabled(true)
    }

    func join() {
        joinMeetingCallback(callConfig)
    }

    private func getPort(_ proto: MediaClient.ProtocolType) -> UInt16 {
        guard let address = RelayURLs(rawValue: relayAddress) else { fatalError() }
        guard let config = relayConfigs[address] else { fatalError() }
        return config[proto] ?? 0
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
                    .padding()
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

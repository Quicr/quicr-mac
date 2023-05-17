import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> Void

private let buttonColour = ActionButtonStyleConfig(
    background: .white,
    foreground: .black
)

private struct LoginForm: View {
    @AppStorage("email") private var email: String = ""
    @AppStorage("relayAddress") private var relayAddress: String = RelayURLs.usWest2.rawValue
    @AppStorage("manifestConfig") private var manifestConfig: Data = .init()

    @State private var isAllowedJoin: Bool = false
    @State private var meetings: [UInt32: String] = [:]

    @State private var callConfig = CallConfig(address: "",
                                               port: relayConfigs[RelayURLs.usWest2]?[.QUIC] ?? 0,
                                               connectionProtocol: .QUIC,
                                               conferenceId: 1)
    private var joinMeetingCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        joinMeetingCallback = onJoin

        guard let config = try? JSONDecoder().decode(ManifestServerConfig.self, from: manifestConfig) else { return }
        ManifestController.shared.setServer(config: config)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Email")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("email", text: $callConfig.email, prompt: Text("example@cisco.com"))
                        .keyboardType(.emailAddress)
                        .onChange(of: callConfig.email, perform: { value in
                            Task {
                                email = value
                                let userId = await ManifestController.shared.getUser(email: email)
                                meetings = await ManifestController.shared.getConferences(for: userId)
                            }
                        })
                        .textFieldStyle(FormInputStyle())
                }

                if email != "" {
                    VStack(alignment: .leading) {
                        Text("Meeting")
                            .padding(.horizontal)
                            .foregroundColor(.white)
                        Picker("", selection: $callConfig.conferenceId) {
                            ForEach(meetings.sorted(by: <), id: \.key) { id, meeting in
                                Text(meeting).tag(id)
                            }
                        }
                        .labelsHidden()
                    }
                }

                RadioButtonGroup("Protocol",
                                 selection: $callConfig,
                                 labels: ["UDP", "QUIC"],
                                 tags: [
                    .init(address: relayAddress,
                          port: getPort(.UDP),
                          connectionProtocol: .UDP,
                          email: callConfig.email,
                          conferenceId: callConfig.conferenceId),
                    .init(address: relayAddress,
                          port: getPort(.QUIC),
                          connectionProtocol: .QUIC,
                          email: callConfig.email,
                          conferenceId: callConfig.conferenceId)
                ])

                ActionButton("Join Meeting",
                             font: Font.system(size: 19, weight: .semibold),
                             disabled: !isAllowedJoin || callConfig.email == "",
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
        .onAppear {
            Task {
                let userId = await ManifestController.shared.getUser(email: email)
                meetings = await ManifestController.shared.getConferences(for: userId)
            }
            callConfig = CallConfig(address: relayAddress,
                                    port: relayConfigs[RelayURLs.usWest2]?[.QUIC] ?? 0,
                                    connectionProtocol: .QUIC,
                                    email: email,
                                    conferenceId: 1)

            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                isAllowedJoin = true
            }
        }
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

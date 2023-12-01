import SwiftUI
import os

typealias ConfigCallback = (_ config: CallConfig) -> Void

private let buttonColour = ActionButtonStyleConfig(
    background: .white,
    foreground: .black
)

private struct LoginForm: View {
    private static let logger = DecimusLogger(LoginForm.self)

    @AppStorage("email")
    private var email: String = ""

    @AppStorage("relayConfig")
    private var relayConfig: AppStorageWrapper<RelayConfig> = .init(value: .init())

    @AppStorage("manifestConfig")
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    @AppStorage("confId")
    private var confId: Int = 0

    @State private var isLoading: Bool = false
    @State private var isAllowedJoin: Bool = false
    @State private var meetings: [UInt32: String] = [:]

    @State private var callConfig = CallConfig(address: "",
                                               port: 0,
                                               connectionProtocol: .QUIC,
                                               conferenceID: 0)
    private var joinMeetingCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        joinMeetingCallback = onJoin
        ManifestController.shared.setServer(config: manifestConfig.value)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Email")
                    TextField("email", text: $callConfig.email, prompt: Text("example@cisco.com"))
                        .keyboardType(.emailAddress)
                        .onChange(of: callConfig.email, perform: { value in
                            email = value
                            Task {
                                do {
                                    try await fetchManifest()
                                } catch {
                                    Self.logger.error("Failed to fetch manifest: \(error.localizedDescription)",
                                                      alert: true)
                                }
                            }
                            if !meetings.keys.contains(UInt32(confId)) {
                                confId = 1
                                callConfig.conferenceID = 1
                            }
                        })
                        .textFieldStyle(FormInputStyle())
                    if isLoading {
                        Spacer()
                        ProgressView()
                    }
                }

                if email != "" {
                    VStack(alignment: .leading) {
                        if meetings.count > 0 {
                            Text("Meeting")
                                .padding(.horizontal)
                                .foregroundColor(.white)
                            Picker("", selection: $callConfig.conferenceID) {
                                ForEach(meetings.sorted(by: <), id: \.key) { id, meeting in
                                    Text(meeting).tag(id)
                                }
                            }
                            .onChange(of: callConfig.conferenceID) { _ in
                                confId = Int(callConfig.conferenceID)
                            }
                            .labelsHidden()
                        } else {
                            Text("No meetings")
                                .padding(.horizontal)
                                .foregroundColor(.white)
                                .onAppear {
                                    callConfig.conferenceID = 0
                                }
                        }
                    }
                }

                if callConfig.conferenceID != 0 {
                    ActionButton("Join Meeting",
                                 font: Font.system(size: 19, weight: .semibold),
                                 disabled: !isAllowedJoin || callConfig.email == "" || callConfig.conferenceID == 0,
                                 styleConfig: buttonColour,
                                 action: join)
                    .frame(maxWidth: .infinity)
                    .font(Font.system(size: 19, weight: .semibold))
                }
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
                do {
                    try await fetchManifest()
                } catch {
                    Self.logger.error("Failed to fetch manifest: \(error.localizedDescription)", alert: true)
                    return
                }
                if meetings.count > 0 {
                    callConfig = CallConfig(address: relayConfig.value.address,
                                            port: relayConfig.value.port,
                                            connectionProtocol: relayConfig.value.connectionProtocol,
                                            email: callConfig.email == "" ? email : callConfig.email,
                                            conferenceID: callConfig.conferenceID == 0 ?
                                            UInt32(confId) : callConfig.conferenceID)
                }
            }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                isAllowedJoin = true
            }
        }
    }

    private func fetchManifest() async throws {
        isLoading = true
        meetings = try await
        ManifestController.shared.getConferences(for: email)
            .reduce(into: [:]) { $0[$1.id] = $1.title }
        callConfig.conferenceID = UInt32(confId)
        isLoading = false
    }

    func join() {
        joinMeetingCallback(callConfig)
    }
}

struct CallSetupView: View {
    private var joinMeetingCallback: ConfigCallback
    @State private var settingsOpen: Bool = false

    init(_ onJoin: @escaping ConfigCallback) {
        UIApplication.shared.isIdleTimerDisabled = false
        joinMeetingCallback = onJoin
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Image("RTMC-Background")
                    .resizable()
                    .scaledToFill()
                    .edgesIgnoringSafeArea(.top)
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

                    NavigationLink(destination: SettingsView()) {
                        Label("", systemImage: "gearshape").font(.title)
                    }
                    .buttonStyle(ActionButtonStyle(styleConfig: .init(background: .clear, foreground: .white),
                                                   cornerRadius: 50,
                                                   isDisabled: false))
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

import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> Void

private struct LoginForm: View {
    @State private var address: String = ""
    @State private var port: UInt16 = 0

    private var configCallback: ConfigCallback

    private let buttonColour = ActionButtonStyleConfig(background: .white, foreground: .black)

    init(_ onJoin: @escaping ConfigCallback) {
        configCallback = onJoin
    }

    var body: some View {
        Form {
            Section {
                FormInput("Address", field: TextField("", text: $address, prompt: Text("")))
                FormInput("Port", field: TextField("",
                                                   value: $port,
                                                   format: .number.grouping(.never),
                                                   prompt: Text("")))
                ActionButton("Join Meeting",
                             font: Font.system(size: 19, weight: .semibold),
                             disabled: address == "" || port == 0,
                             styleConfig: buttonColour,
                             action: join)
                .frame(maxWidth: .infinity)
                .font(Font.system(size: 19, weight: .semibold))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // TODO: For Dev purposes, should be removed eventually
            Section {
                HStack {
                    ActionButton("localhost",
                                 font: Font.system(size: 19, weight: .semibold),
                                 styleConfig: buttonColour, action: {
                        address = "127.0.0.1"
                        port = 1234
                    })
                    .font(Font.system(size: 19, weight: .semibold))
                    ActionButton("AWS",
                                 font: Font.system(size: 19, weight: .semibold),
                                 styleConfig: buttonColour, action: {
                        address = "relay.us-west-2.quicr.ctgpoc.com"
                        port = 33434
                    })
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .background(.clear)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
    }

    func join() {
        configCallback(.init(address: address, port: port))
    }
}

struct CallSetupView: View {
    private var configCallback: ConfigCallback

    init(_ onJoin: @escaping ConfigCallback) {
        configCallback = onJoin
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
                    LoginForm(configCallback)
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

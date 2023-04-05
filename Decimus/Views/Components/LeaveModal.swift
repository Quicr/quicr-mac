import SwiftUI

struct LeaveModal: View {
    private let leaveAction: () -> Void
    private let cancelAction: () -> Void

    init(leaveAction: @escaping () -> Void, cancelAction: @escaping () -> Void) {
        self.leaveAction = leaveAction
        self.cancelAction = cancelAction
    }

    init(leaveAction: @escaping () async -> Void, cancelAction: @escaping () async -> Void) {
        self.leaveAction = { Task { await leaveAction() }}
        self.cancelAction = { Task { await cancelAction() }}
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.gray, lineWidth: 1)
                .background(.black)
            VStack(alignment: .leading) {
                Text("Leave Meeting")
                    .foregroundColor(.white)
                    .font(.title)
                    .padding(.bottom)
                Text("Do you want to leave this meeting?")
                    .foregroundColor(.gray)
                    .font(.body)
                    .padding(.bottom)
                HStack {
                    #if targetEnvironment(macCatalyst)
                    Spacer().frame(maxWidth: .infinity)
                    #endif
                    ActionButton("Cancel",
                                 styleConfig: ActionButtonStyleConfig(
                                    background: .black,
                                    foreground: .white,
                                    borderColour: .gray),
                                 action: cancelAction)
                    ActionButton("Leave Meeting",
                                 styleConfig: ActionButtonStyleConfig(
                                    background: .white,
                                    foreground: .black),
                                 action: leaveAction)
                }
                #if !targetEnvironment(macCatalyst)
                .frame(alignment: .center)
                #else
                .frame(alignment: .trailing)
                #endif
            }
            .padding()
        }
        .cornerRadius(12)
    }
}

import SwiftUI
import CoreMedia

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {

    @Published var available = false

    var videoCallback: CaptureManager.MediaCallback?
    var audioCallback: CaptureManager.MediaCallback?
    var deviceChangeCallback: CaptureManager.DeviceChangeCallback?
    var manager: CaptureManager?

    init(errorHandler: ErrorWriter) {
        manager = .init(
            cameraCallback: { identifier, sample in
                self.videoCallback?(identifier, sample)
            },
            audioCallback: { identifier, sample in
                self.audioCallback?(identifier, sample)
            },
            deviceChangeCallback: { identifier, event in
                self.deviceChangeCallback?(identifier, event)
            },
            available: { available in
                DispatchQueue.main.async { self.available = available }
            },
            errorHandler: errorHandler,
            currentOrientation: UIDevice.current.orientation.videoOrientation)
    }
}

class Modes: ObservableObject {

    let qMedia: QMediaPubSub
    let loopback: Loopback
    let rawLoopback: RawLoopback

    init(participants: VideoParticipants, errorWriter: ErrorWriter) {
        let player: AudioPlayer = .init(fileWrite: false)
        qMedia = .init(participants: participants, player: player, errorWriter: errorWriter)
        loopback = .init(participants: participants, player: player, errorWriter: errorWriter)
        rawLoopback = .init(participants: participants, player: player, errorWriter: errorWriter)
    }
}

class ObservableError: ObservableObject, ErrorWriter {
    struct StringError: Identifiable {
        let id = UUID()
        let message: String
    }

    @Published var messages: [StringError] = []
    func writeError(message: String) {
        print("[Decimus Error] => \(message)")
        self.messages.append(.init(message: message))
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    internal func scene(_ scene: UIScene,
                        willConnectTo session: UISceneSession,
                        options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        #if targetEnvironment(macCatalyst)
        if let titlebar = windowScene.titlebar {
            titlebar.titleVisibility = .hidden
            titlebar.toolbar = nil
        }
        #endif
    }
}

@main
struct DecimusApp: App {
    @StateObject private var participants: VideoParticipants
    @StateObject private var devices: AudioVideoDevices = .init()
    @StateObject private var captureManager: ObservableCaptureManager
    @StateObject private var modes: Modes
    @StateObject private var errorHandler: ObservableError

    init() {
        let errorHandler: ObservableError = .init()
        let observableCaptureManager: ObservableCaptureManager = .init(errorHandler: errorHandler)
        _errorHandler = .init(wrappedValue: errorHandler)
        _captureManager = .init(wrappedValue: observableCaptureManager)
        let participants: VideoParticipants = .init()
        _participants = .init(wrappedValue: participants)
        _modes = .init(wrappedValue: .init(participants: participants, errorWriter: errorHandler))
    }

    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(devices)
                .environmentObject(participants)
                .environmentObject(captureManager)
                .environmentObject(modes)
                .environmentObject(errorHandler)
                .withHostingWindow { window in
                    #if targetEnvironment(macCatalyst)
                    if let titlebar = window?.windowScene?.titlebar {
                        titlebar.titleVisibility = .hidden
                        titlebar.toolbar = nil
                    }
                    #endif
                }
                .preferredColorScheme(.dark)
        }
    }
}

extension View {
    fileprivate func withHostingWindow(_ callback: @escaping (UIWindow?) -> Void) -> some View {
        self.background(HostingWindowFinder(callback: callback))
    }
}

private struct HostingWindowFinder: UIViewRepresentable {
    var callback: (UIWindow?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async { [weak view] in
            self.callback(view?.window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
    }
}

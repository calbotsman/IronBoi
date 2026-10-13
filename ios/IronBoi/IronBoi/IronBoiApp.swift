import FirebaseAppCheck
import FirebaseCore
import SwiftUI

@main
struct IronBoiApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        // App Check provider MUST be set BEFORE FirebaseApp.configure().
        //
        // DEBUG: do NOT install a provider. The debug provider can't mint a
        // valid token unless its (per-install) debug token is registered in
        // the console, and an *invalid* token is rejected by callables even
        // when enforcement is off. With no provider, the app sends no token
        // (app:MISSING), which passes while enforcement is disabled. This is
        // why profile saves / plan rebuilds were failing on device.
        //
        // RELEASE: App Attest, for when App Check enforcement is turned back
        // on before the public launch. See AppCheckProviderFactory.swift.
        #if !DEBUG
        AppCheck.setAppCheckProviderFactory(IronBoiAppCheckProviderFactory())
        #endif
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appModel)
                // The app is printed on the paper you picked, not on the
                // system's Dark Mode: light papers force the light scheme
                // (so SwiftUI never puts white text on cream), Night forces
                // dark, so system controls match it.
                .modifier(PaperScheme())
                // Doctrine: selection is the coach's red pen. This sets
                // tab selection, links, and any control without an
                // explicit tint to brick instead of system blue.
                .tint(MyoTheme.Colors.brick)
        }
    }
}

struct AppRootView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Group {
            if appModel.user != nil && !appModel.profileLoaded {
                // Signed in, profile still loading: plain paper, no guessing.
                PaperBackground().ignoresSafeArea()
            } else if appModel.user != nil && appModel.onboardingStatus != .complete {
                // Same stage as home: the coach asks, you tap, talk or type.
                OnboardingStageView()
            } else {
                // One screen: the coach. Plan, History and You live behind
                // the profile icon in its corner.
                CoachView()
                .sheet(isPresented: $appModel.showProfile) {
                    PreferencesView()
                }
            }
        }
        .task {
            appModel.start()
        }
        #if DEBUG
        // MYO_LIVE_PROBE=1: once signed in, open a live voice session, say
        // one line to it, and log what comes back — tests the real socket,
        // token, audio and captions without clicking through onboarding.
        .task(id: appModel.user?.uid) {
            guard ProcessInfo.processInfo.environment["MYO_LIVE_PROBE"] == "1", appModel.user != nil else { return }
            // Two separate sessions: say something to remember, hang up,
            // then ask for it back. Proves memory crosses sessions.
            @MainActor func turn(_ line: String) async -> String {
                let live = LiveVoiceSession()
                let started = await live.start(appModel.liveBackend)
                AudioHub.log("probe: started=\(started)")
                for _ in 0..<60 where live.state == .connecting { try? await Task.sleep(nanoseconds: 250_000_000) }
                live.debugSay(line)
                for _ in 0..<80 { try? await Task.sleep(nanoseconds: 250_000_000) }
                let said = live.caption
                live.stop()
                return said
            }
            let first = await turn("Remember this for next week: I only have dumbbells and a bench at home, no barbell.")
            AudioHub.log("probe 1 reply: \"\(first.suffix(140))\"")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let second = await turn("What equipment do I have at home right now?")
            AudioHub.log("probe 2 reply: \"\(second.suffix(140))\"")
        }
        #endif
    }
}

/// The colour scheme follows the paper, not the system.
private struct PaperScheme: ViewModifier {
    func body(content: Content) -> some View {
        content.preferredColorScheme(PaperStore.shared.paper.isDark ? .dark : .light)
    }
}

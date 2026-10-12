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
                // The design uses a fixed cream paper background that
                // doesn't switch on Dark Mode. Force the app into light
                // scheme so SwiftUI doesn't auto-pick white text on
                // cream and make everything unreadable. Cream-always is
                // doctrine (Deter ruled forced-light is the intent).
                .preferredColorScheme(.light)
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
                OnboardingView()
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
            let live = LiveVoiceSession()
            let started = await live.start { try await appModel.startLiveCoachSession() }
            AudioHub.log("probe: started=\(started)")
            for _ in 0..<40 where live.state == .connecting { try? await Task.sleep(nanoseconds: 250_000_000) }
            live.debugSay("Quick one: how many sets should I do today?")
            for _ in 0..<80 { try? await Task.sleep(nanoseconds: 250_000_000) }
            AudioHub.log("probe: done state=\(live.state) caption=\"\(live.caption.suffix(120))\"")
            live.stop()
        }
        #endif
    }
}


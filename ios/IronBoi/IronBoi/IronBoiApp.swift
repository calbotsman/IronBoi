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
            if appModel.user != nil && appModel.onboardingStatus != .complete {
                OnboardingView()
            } else {
                TabView(selection: $appModel.selectedTab) {
                    CoachView()
                        .tabItem {
                            Label("Coach", systemImage: "message.fill")
                        }
                        .tag(AppModel.AppTab.coach)

                    WorkoutView()
                        .tabItem {
                            Label("Train", systemImage: "checklist")
                        }
                        .tag(AppModel.AppTab.workout)

                    RecordView()
                        .tabItem {
                            Label("Record", systemImage: "chart.bar.fill")
                        }
                        .tag(AppModel.AppTab.progress)

                    PreferencesView()
                        .tabItem {
                            Label("You", systemImage: "person.crop.circle")
                        }
                        .tag(AppModel.AppTab.you)
                }
            }
        }
        .task {
            appModel.start()
        }
    }
}


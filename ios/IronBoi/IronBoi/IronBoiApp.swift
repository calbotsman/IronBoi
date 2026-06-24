import FirebaseAppCheck
import FirebaseCore
import SwiftUI

@main
struct IronBoiApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        // Phase 3 Task 3.2 — App Check provider MUST be set BEFORE
        // FirebaseApp.configure(). After configure() runs, the factory
        // can't be swapped without app restart. See
        // Services/AppCheckProviderFactory.swift for the Debug/Release
        // provider choice + first-run setup steps.
        AppCheck.setAppCheckProviderFactory(IronBoiAppCheckProviderFactory())
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


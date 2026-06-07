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
                // cream and make everything unreadable. Revisit when
                // we ship real Dark Mode color assets.
                .preferredColorScheme(.light)
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
                            Label("Workout", systemImage: "checklist")
                        }
                        .tag(AppModel.AppTab.workout)

                    ProgressPlaceholderView()
                        .tabItem {
                            Label("Progress", systemImage: "chart.bar.fill")
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

private struct ProgressPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Progress",
                systemImage: "chart.bar.fill",
                description: Text("Workout history, streaks, and metrics land here next.")
            )
            .navigationTitle("Progress")
        }
    }
}

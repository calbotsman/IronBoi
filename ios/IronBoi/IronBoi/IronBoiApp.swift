import FirebaseCore
import SwiftUI

@main
struct IronBoiApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appModel)
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

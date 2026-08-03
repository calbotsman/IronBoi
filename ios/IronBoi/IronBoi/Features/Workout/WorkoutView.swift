import SwiftUI
import UIKit

struct WorkoutView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedDemoExercise: PlannedExercise?

    var body: some View {
        NavigationStack {
            Group {
                if !appModel.hasSession {
                    signedOutView
                } else if let workout = appModel.activeWorkout {
                    ActiveWorkoutView(workout: workout)
                } else {
                    planView
                }
            }
            .navigationTitle("Train")
            // The plan summary bakes in "today's" dailyOverride; an app
            // resident across midnight would show yesterday's splice until
            // the next server write. Re-derive from the cached doc whenever
            // the app comes back to the foreground.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appModel.recomputeCurrentWorkoutPlanForToday()
                }
            }
            .alert("MYO", isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {
                    appModel.errorMessage = nil
                }
            } message: {
                Text(appModel.errorMessage ?? "")
            }
            .sheet(item: $selectedDemoExercise) { exercise in
                PlannedExerciseDetailSheet(dayKey: "Demo", exercise: exercise)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            // Rebaseline card. Lives at the root of the tab rather than
            // inside ActiveWorkoutView because finishing tears that view
            // down — a sheet attached to it would be dismissed with it.
            .sheet(isPresented: Binding(
                get: { !appModel.pendingBaselineSuggestions.isEmpty },
                set: { if !$0 { appModel.dismissBaselineSuggestions() } }
            )) {
                BaselineUpdateSheet(suggestions: appModel.pendingBaselineSuggestions)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var signedOutView: some View {
        ContentUnavailableView {
            Label("Sign in to start workouts", systemImage: "figure.strengthtraining.traditional")
        } description: {
            Text("Your workouts, logs, and coach context are stored under your private account.")
        } actions: {
            Button("Sign in with Apple") {
                appModel.signInWithApple()
            }
            .buttonStyle(.borderedProminent)
            .tint(MyoTheme.Colors.ink)

            #if DEBUG
            Button {
                appModel.startPreviewSession()
            } label: {
                Label("Preview the app (no backend)", systemImage: "eye")
            }
            .buttonStyle(.borderedProminent)
            .tint(MyoColor.Action.primary.color)
            .foregroundStyle(MyoColor.Text.primary.color)

            Button("Dev sign-in (anonymous)") {
                Task { await appModel.signInAsDeveloper() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(MyoColor.Text.secondary.color)
            #endif
        }
    }

    private var planView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                kettlebellSwingDemoCard

                if let plan = appModel.currentWorkoutPlan, !plan.days.isEmpty {
                    WeeklyPlanView(plan: plan)
                } else {
                    noPlanView
                }
            }
            .padding()
        }
        .background(PaperBackground())
    }

    private var kettlebellSwingDemoCard: some View {
        Button {
            selectedDemoExercise = PlannedExercise(
                name: "KB Swing",
                sets: 4,
                reps: 12,
                weight: 35
            )
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(MyoTheme.Colors.ink)
                    .frame(width: 48, height: 48)
                    .background(MyoTheme.Colors.ochreLight)
                    .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Try the Movement Sequence")
                        .font(.headline)
                        .foregroundStyle(MyoTheme.Colors.ink)

                    Text("Preview the illustrated kettlebell swing frames.")
                        .font(.subheadline)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }
            .padding()
            .background(MyoTheme.Colors.cream)
            .overlay {
                RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                    .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var noPlanView: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("No Plan Yet")
                    .font(.largeTitle.bold())

                Text("Finish onboarding and accept your MYO plan. Your week of workouts will appear here.")
                    .font(.body)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }

            Button {
                Task {
                    await appModel.startTodaysWorkout()
                }
            } label: {
                Label(appModel.isWorkoutBusy ? "Starting..." : "Start Starter Workout", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(MyoColor.Action.primary.color)
            .foregroundStyle(MyoColor.Text.primary.color)
            .disabled(appModel.isWorkoutBusy)
        }
    }
}

private struct WeeklyPlanView: View {
    @EnvironmentObject private var appModel: AppModel
    let plan: WorkoutPlanSummary

    private var todayKey: String {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday - 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("This Week")
                    .font(.largeTitle.bold())

                Text("Your accepted MYO plan. Tap a day to review the work, then start it when you are ready.")
                    .font(.body)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }

            ForEach(plan.days) { day in
                PlannedWorkoutDayCard(
                    day: day,
                    isToday: day.dayKey == todayKey,
                    isBusy: appModel.isWorkoutBusy
                ) {
                    Task {
                        await appModel.startWorkout(dayKey: day.dayKey)
                    }
                }
            }
        }
    }
}

private struct PlannedWorkoutDayCard: View {
    let day: PlannedWorkoutDay
    let isToday: Bool
    let isBusy: Bool
    let start: () -> Void

    @State private var isExpanded = false
    @State private var selectedExercise: PlannedExercise?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(MyoTheme.Motion.fade) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        Text(day.dayKey)
                            .font(.headline.weight(.black))

                        if isToday {
                            Text("Today")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(MyoTheme.Colors.ochreLight)
                                .foregroundStyle(MyoTheme.Colors.ink)
                                .clipShape(Capsule())
                        }
                    }
                    .frame(width: 54)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(day.name)
                                .font(.headline)
                                .foregroundStyle(MyoTheme.Colors.ink)
                                .fixedSize(horizontal: false, vertical: true)

                            if day.isAdjusted {
                                // Coach-adjusted (temporary override) — the
                                // red-pen accent matches the coach's voice
                                // elsewhere in the app.
                                Text("ADJUSTED")
                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                    .kerning(0.5)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(MyoColor.redPen.opacity(0.12))
                                    .foregroundStyle(MyoColor.redPen)
                                    .clipShape(Capsule())
                            }
                        }

                        Text(summaryText)
                            .font(.subheadline)
                            .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.headline)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                        .padding(.top, 2)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !day.muscles.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(day.muscles, id: \.self) { muscle in
                                Text(muscle)
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(MyoTheme.Colors.ochre.opacity(0.18))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    ForEach(day.exercises) { exercise in
                        Button {
                            selectedExercise = exercise
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(exercise.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(MyoTheme.Colors.ink)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer()

                                Text(targetText(for: exercise))
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

                                Image(systemName: "info.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }

                    Button(action: start) {
                        Label(isBusy ? "Starting..." : "Start \(day.dayKey)", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MyoColor.Action.primary.color)
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .disabled(isBusy)
                    .padding(.top, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
        .sheet(item: $selectedExercise) { exercise in
            PlannedExerciseDetailSheet(dayKey: day.dayKey, exercise: exercise)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var summaryText: String {
        "\(day.exercises.count) exercises · \(day.totalSets) sets"
    }

    private func targetText(for exercise: PlannedExercise) -> String {
        let weight = exercise.weight > 0 ? " · \(Int(exercise.weight)) lb" : ""
        return "\(exercise.sets)x\(exercise.reps)\(weight)"
    }
}

private struct PlannedExerciseDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    let dayKey: String
    let exercise: PlannedExercise
    @State private var coachRequest = ""
    @State private var isSwapping = false

    private var knowledge: ExerciseKnowledge {
        ExerciseKnowledge.lookup(exercise.name)
    }

    private var sequence: ExerciseSequence? {
        ExerciseSequence.lookup(exerciseName: exercise.name)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    if let sequence {
                        ExerciseSequencePlayer(sequence: sequence)
                    }
                    statsRow
                    swapButton
                    musclesSection
                    cuesSection
                    askCoachSection
                    videoButton
                }
                .padding()
            }
            .background(MyoTheme.Colors.cream.ignoresSafeArea())
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isSwapping) {
                ExerciseSwapSheet(
                    dayKey: dayKey,
                    exerciseName: exercise.name,
                    sessionId: nil,
                    // No workout is running, so there is no "just this
                    // workout" — the choice is today's session or the
                    // repeating plan.
                    allowedScopes: [.today, .goingForward]
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var swapButton: some View {
        Button {
            isSwapping = true
        } label: {
            Label("Swap for something else", systemImage: "arrow.triangle.swap")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(MyoTheme.Colors.ink)
        // The demo card passes a synthetic "Demo" dayKey for an exercise that
        // isn't in any plan — there is nothing to swap it in.
        .disabled(dayKey == "Demo")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exercise.name)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .minimumScaleFactor(0.72)

            Text(detailSubtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatTile(label: "Sets", value: "\(exercise.sets)")
            StatTile(label: isTimed ? "Sec" : "Reps", value: "\(exercise.reps)")
            StatTile(label: "Weight", value: exercise.weight > 0 ? "\(Int(exercise.weight)) lb" : "BW")
        }
    }

    private var musclesSection: some View {
        DetailSection(title: "Muscles Worked") {
            VStack(alignment: .leading, spacing: 12) {
                MuscleChipGroup(title: "Primary", muscles: knowledge.primary, tint: MyoTheme.Colors.ochre)
                MuscleChipGroup(title: "Secondary", muscles: knowledge.secondary, tint: MyoTheme.Colors.ink)
            }
        }
    }

    private var cuesSection: some View {
        DetailSection(title: "Form Cues") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(knowledge.cues.enumerated()), id: \.offset) { index, cue in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(MyoTheme.Colors.ink)
                            .frame(width: 28, height: 28)
                            .background(MyoTheme.Colors.ochreLight)
                            .clipShape(Circle())

                        Text(cue)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var videoButton: some View {
        Link(destination: videoURL) {
            Label(knowledge.youtubeVideoId == nil ? "Search Demo" : "Watch Demo", systemImage: "play.rectangle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(MyoColor.Action.primary.color)
        .foregroundStyle(MyoColor.Text.primary.color)
    }

    private var askCoachSection: some View {
        DetailSection(title: "Ask Coach") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Ask for a swap, an easier variation, or a better demo", text: $coachRequest, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                // "Change weight" used to live here. It sent the user into a
                // plan-adjustment flow that could never be applied, and a
                // number is faster to type than to negotiate — the stepper on
                // the exercise card owns that now. Chat is for the things a
                // control can't express ("my basement ceiling is too low").
                HStack(spacing: 8) {
                    quickAskButton("Won't fit my space", request: "This movement doesn't work in my space. Can you swap it for something that trains the same thing?")
                    quickAskButton("Better demo", request: "Can you find me a better picture or demo for this exercise?")
                }

                FlowLayout(spacing: 8) {
                    quickAskButton("Too hard", request: "This is too hard for me right now. Can you swap it for an easier variation?")
                    quickAskButton("Less time", request: "I have less time today. Can you shorten this workout?")
                    quickAskButton("Skip today", request: "I have to skip this workout today. Can you adjust my week?")
                    quickAskButton("Pain/injury", request: "Something hurts. Can you help me adjust this workout safely?")
                    quickAskButton("Different style", request: "I want to try a different workout style today, like yoga or mobility.")
                }

                Button {
                    let request = coachRequest.isEmpty ? "Can we adjust this workout?" : coachRequest
                    Task {
                        await appModel.askCoachAboutWorkout(
                            dayKey: dayKey,
                            exercise: exercise,
                            request: request
                        )
                        dismiss()
                    }
                } label: {
                    Label(appModel.isSending ? "Sending..." : "Send to Coach", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MyoColor.Action.primary.color)
                .foregroundStyle(MyoColor.Text.primary.color)
                .disabled(appModel.isSending)
            }
        }
    }

    private func quickAskButton(_ title: String, request: String) -> some View {
        Button(title) {
            coachRequest = request
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var detailSubtitle: String {
        let repLabel = isTimed ? "seconds" : "reps"
        let weight = exercise.weight > 0 ? " at \(Int(exercise.weight)) lb" : " bodyweight"
        return "\(exercise.sets) sets x \(exercise.reps) \(repLabel)\(weight)"
    }

    private var isTimed: Bool {
        let lower = exercise.name.lowercased()
        return lower.contains("plank") || lower.contains("jog") || lower.contains("sprint")
    }

    private var videoURL: URL {
        // Prefer the curated YouTube videoId when we have one. Build the
        // URL with URLComponents + URLQueryItem so any special characters
        // in the videoId (`&`, `=`, `?`, ` `, etc.) get properly percent-
        // encoded. String interpolation does NOT escape and YouTube would
        // read an unescaped `&` as a separate query parameter.
        if let videoId = knowledge.youtubeVideoId,
           !videoId.isEmpty,
           var components = URLComponents(string: "https://www.youtube.com/watch") {
            components.queryItems = [URLQueryItem(name: "v", value: videoId)]
            if let watchURL = components.url {
                return watchURL
            }
        }

        // Fall back to a YouTube search. Same URLComponents pattern —
        // URLQueryItem handles the spaces, ampersands, and unicode in
        // the exercise name correctly. No manual percent-encoding needed.
        if var components = URLComponents(string: "https://www.youtube.com/results") {
            components.queryItems = [
                URLQueryItem(
                    name: "search_query",
                    value: "\(exercise.name) exercise form tutorial"
                ),
            ]
            if let searchURL = components.url {
                return searchURL
            }
        }

        // Last resort: YouTube homepage. The string is a known-good
        // literal so the trailing `!` cannot crash here.
        return URL(string: "https://www.youtube.com")!
    }
}

private struct ActiveWorkoutView: View {
    @EnvironmentObject private var appModel: AppModel
    let workout: ActiveWorkoutSession
    @State private var selectedExercise: ActiveWorkoutExercise?
    @State private var swappingExercise: ActiveWorkoutExercise?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                ForEach(workout.exercises) { exercise in
                    WorkoutExerciseCard(
                        exercise: exercise,
                        showDetails: { selectedExercise = exercise },
                        requestSwap: { swappingExercise = exercise }
                    )
                }

                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Task {
                        await appModel.finishActiveWorkout()
                    }
                } label: {
                    Label(appModel.isWorkoutBusy ? "Finishing..." : "End Workout", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(MyoColor.Action.primary.color)
                .foregroundStyle(MyoColor.Text.primary.color)
                .disabled(appModel.isWorkoutBusy)
                .padding(.top, 8)
            }
            .padding()
        }
        .sheet(item: $selectedExercise) { exercise in
            ExerciseDetailSheet(
                exercise: exercise,
                dayKey: workout.dayKey,
                sessionId: workout.sessionId
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $swappingExercise) { exercise in
            ExerciseSwapSheet(
                dayKey: workout.dayKey,
                exerciseName: exercise.name,
                sessionId: workout.sessionId,
                // Mid-workout, "just this workout" is the common case and
                // leads — most swaps here are about today's equipment or
                // energy, not a standing change to the program.
                allowedScopes: [.session, .today, .goingForward]
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workout.dayKey)
                .font(MyoTheme.Typography.monoLabel)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                .textCase(.uppercase)

            Text(workout.workoutName)
                .font(.largeTitle.bold())

            Text("\(completedSets)/\(totalSets) sets complete")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

            ProgressView(value: Double(completedSets), total: Double(max(totalSets, 1)))
                .tint(MyoTheme.Colors.ochre)
        }
    }

    private var totalSets: Int {
        workout.exercises.reduce(0) { $0 + $1.completedSets.count }
    }

    private var completedSets: Int {
        workout.exercises.reduce(0) { $0 + $1.completedSetCount }
    }
}

private struct WorkoutExerciseCard: View {
    @EnvironmentObject private var appModel: AppModel
    let exercise: ActiveWorkoutExercise
    let showDetails: () -> Void
    let requestSwap: () -> Void

    var body: some View {
        Button(action: showDetails) {
            VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.headline)
                        .foregroundStyle(MyoTheme.Colors.ink)

                    Text(targetText)
                        .font(.subheadline)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }

                Spacer()

                // Mid-workout swap, one tap from the card. Burying this in
                // the detail sheet would mean three taps at the exact moment
                // someone has found the rack occupied.
                Button(action: requestSwap) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.title3)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.55))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Swap \(exercise.name) for another exercise")

                Button {
                    if !exercise.exerciseDone {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    appModel.toggleExerciseDone(exerciseIndex: exercise.exerciseIndex)
                } label: {
                    Image(systemName: exercise.exerciseDone ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(exercise.exerciseDone ? MyoTheme.Colors.ochre : MyoTheme.Colors.ink.opacity(0.45))
                }
                .accessibilityLabel(exercise.exerciseDone ? "Mark exercise not done" : "Mark exercise done")
            }

            // Weight is recorded here or nowhere — the set toggle stamps
            // whatever this shows. Bodyweight movements (target 0) get no
            // control; a stepper on push-ups is noise.
            if exercise.targetWeight > 0 {
                WorkoutWeightStepper(
                    weight: appModel.workingWeight(for: exercise),
                    isPrescribed: appModel.workingWeight(for: exercise) == exercise.targetWeight
                ) { newWeight in
                    appModel.setWorkoutExerciseWeight(
                        exerciseIndex: exercise.exerciseIndex,
                        weight: newWeight
                    )
                }
            }

            HStack(spacing: 8) {
                ForEach(exercise.completedSets) { set in
                    Button {
                        if !set.completed {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        appModel.toggleWorkoutSet(
                            exerciseIndex: exercise.exerciseIndex,
                            setIndex: set.setIndex
                        )
                    } label: {
                        Text(set.completed ? "✓" : "S\(set.setIndex + 1)")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(set.completed ? MyoTheme.Colors.ochre : MyoTheme.Colors.ink.opacity(0.06))
                    .foregroundStyle(set.completed ? MyoTheme.Colors.cream : MyoTheme.Colors.ink)
                    .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
                    .accessibilityLabel("Toggle set \(set.setIndex + 1)")
                }

                Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                    .frame(width: 44, height: 48)
                    .accessibilityHidden(true)
            }
        }
        .padding()
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens exercise details, muscles worked, and form cues.")
    }

    private var targetText: String {
        let weight = exercise.targetWeight > 0 ? " · \(Int(exercise.targetWeight)) lb" : ""
        return "\(exercise.targetSets)x\(exercise.targetReps)\(weight)"
    }
}

private struct ExerciseDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: ActiveWorkoutExercise
    let dayKey: String
    let sessionId: String
    @State private var isSwapping = false

    private var knowledge: ExerciseKnowledge {
        ExerciseKnowledge.lookup(exercise.name)
    }

    private var sequence: ExerciseSequence? {
        ExerciseSequence.lookup(exerciseName: exercise.name)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    if let sequence {
                        ExerciseSequencePlayer(sequence: sequence)
                    }
                    statsRow
                    swapButton
                    musclesSection
                    cuesSection
                    videoButton
                }
                .padding()
            }
            .background(MyoTheme.Colors.cream.ignoresSafeArea())
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isSwapping) {
                ExerciseSwapSheet(
                    dayKey: dayKey,
                    exerciseName: exercise.name,
                    sessionId: sessionId,
                    allowedScopes: [.session, .today, .goingForward]
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var swapButton: some View {
        Button {
            isSwapping = true
        } label: {
            Label("Swap for something else", systemImage: "arrow.triangle.swap")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(MyoTheme.Colors.ink)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exercise.name)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .minimumScaleFactor(0.72)

            Text(detailSubtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatTile(label: "Sets", value: "\(exercise.targetSets)")
            StatTile(label: isTimed ? "Sec" : "Reps", value: "\(exercise.targetReps)")
            StatTile(label: "Weight", value: exercise.targetWeight > 0 ? "\(Int(exercise.targetWeight)) lb" : "BW")
        }
    }

    private var musclesSection: some View {
        DetailSection(title: "Muscles Worked") {
            VStack(alignment: .leading, spacing: 12) {
                MuscleChipGroup(title: "Primary", muscles: knowledge.primary, tint: MyoTheme.Colors.ochre)
                MuscleChipGroup(title: "Secondary", muscles: knowledge.secondary, tint: MyoTheme.Colors.ink)
            }
        }
    }

    private var cuesSection: some View {
        DetailSection(title: "Form Cues") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(knowledge.cues.enumerated()), id: \.offset) { index, cue in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(MyoTheme.Colors.ink)
                            .frame(width: 28, height: 28)
                            .background(MyoTheme.Colors.ochreLight)
                            .clipShape(Circle())

                        Text(cue)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var videoButton: some View {
        Link(destination: videoURL) {
            Label(knowledge.youtubeVideoId == nil ? "Search Demo" : "Watch Demo", systemImage: "play.rectangle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(MyoColor.Action.primary.color)
        .foregroundStyle(MyoColor.Text.primary.color)
    }

    private var detailSubtitle: String {
        let repLabel = isTimed ? "seconds" : "reps"
        let weight = exercise.targetWeight > 0 ? " at \(Int(exercise.targetWeight)) lb" : " bodyweight"
        return "\(exercise.targetSets) sets x \(exercise.targetReps) \(repLabel)\(weight)"
    }

    private var isTimed: Bool {
        let lower = exercise.name.lowercased()
        return lower.contains("plank") || lower.contains("jog") || lower.contains("sprint")
    }

    private var videoURL: URL {
        // Prefer the curated YouTube videoId when we have one. Build the
        // URL with URLComponents + URLQueryItem so any special characters
        // in the videoId (`&`, `=`, `?`, ` `, etc.) get properly percent-
        // encoded. String interpolation does NOT escape and YouTube would
        // read an unescaped `&` as a separate query parameter.
        if let videoId = knowledge.youtubeVideoId,
           !videoId.isEmpty,
           var components = URLComponents(string: "https://www.youtube.com/watch") {
            components.queryItems = [URLQueryItem(name: "v", value: videoId)]
            if let watchURL = components.url {
                return watchURL
            }
        }

        // Fall back to a YouTube search. Same URLComponents pattern —
        // URLQueryItem handles the spaces, ampersands, and unicode in
        // the exercise name correctly. No manual percent-encoding needed.
        if var components = URLComponents(string: "https://www.youtube.com/results") {
            components.queryItems = [
                URLQueryItem(
                    name: "search_query",
                    value: "\(exercise.name) exercise form tutorial"
                ),
            ]
            if let searchURL = components.url {
                return searchURL
            }
        }

        // Last resort: YouTube homepage. The string is a known-good
        // literal so the trailing `!` cannot crash here.
        return URL(string: "https://www.youtube.com")!
    }
}

/// Pick a different movement that trains the same thing.
///
/// Options are server-ranked and server-validated — the same catalog gates
/// `swapExercise`, so the user can only ever apply something from this list.
/// Reachable both from a planned exercise (before starting) and from an
/// exercise inside a running workout; `allowedScopes` is what differs.
struct ExerciseSwapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel

    let dayKey: String
    let exerciseName: String
    /// Non-nil when a workout is running — enables the "just this workout"
    /// scope and lets the server read the live session for context.
    let sessionId: String?
    let allowedScopes: [SwapScope]

    @State private var options: [ExerciseSwapOption] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var failureMessage: String?
    @State private var selectedEquipment: Set<String> = []
    @State private var bodyweightOnly = false
    @State private var scope: SwapScope
    @State private var applyingOption: String?

    // Only the gear the catalog actually filters on. "none" is never a
    // filter — a movement needing nothing is available to everyone.
    private static let equipmentFilters: [(id: String, label: String)] = [
        ("dumbbell", "Dumbbells"),
        ("barbell", "Barbell"),
        ("kettlebell", "Kettlebell"),
        ("bench", "Bench"),
        ("pullup_bar", "Pull-up bar"),
        ("band", "Bands"),
    ]

    init(dayKey: String, exerciseName: String, sessionId: String?, allowedScopes: [SwapScope]) {
        self.dayKey = dayKey
        self.exerciseName = exerciseName
        self.sessionId = sessionId
        self.allowedScopes = allowedScopes
        _scope = State(initialValue: allowedScopes.first ?? .today)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let failureMessage {
                        Text(failureMessage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MyoColor.redPen)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(MyoColor.redPen.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
                    }
                    equipmentSection
                    scopeSection
                    optionsSection
                }
                .padding()
            }
            .background(MyoTheme.Colors.cream.ignoresSafeArea())
            .navigationTitle("Swap Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Replacing")
                .font(MyoTheme.Typography.monoLabel)
                .textCase(.uppercase)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

            Text(exerciseName)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            Text("These all train the same primary muscles.")
                .font(.subheadline)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
        }
    }

    private var equipmentSection: some View {
        DetailSection(title: "What do you have?") {
            VStack(alignment: .leading, spacing: 10) {
                FlowLayout(spacing: 8) {
                    filterChip(
                        label: "No equipment",
                        isOn: bodyweightOnly
                    ) {
                        bodyweightOnly.toggle()
                        if bodyweightOnly { selectedEquipment.removeAll() }
                        Task { await reload() }
                    }

                    ForEach(Self.equipmentFilters, id: \.id) { filter in
                        filterChip(
                            label: filter.label,
                            isOn: selectedEquipment.contains(filter.id)
                        ) {
                            bodyweightOnly = false
                            if selectedEquipment.contains(filter.id) {
                                selectedEquipment.remove(filter.id)
                            } else {
                                selectedEquipment.insert(filter.id)
                            }
                            Task { await reload() }
                        }
                    }
                }

                Text(filterExplanation)
                    .font(.caption)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }
        }
    }

    private var filterExplanation: String {
        if bodyweightOnly { return "Showing movements that need nothing at all." }
        if selectedEquipment.isEmpty { return "Nothing selected — showing everything." }
        return "Showing movements you can do with what you picked."
    }

    private func filterChip(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(isOn ? MyoTheme.Colors.ochre : MyoTheme.Colors.ink.opacity(0.06))
                .foregroundStyle(isOn ? MyoTheme.Colors.cream : MyoTheme.Colors.ink)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    @ViewBuilder
    private var scopeSection: some View {
        // A single allowed scope needs no picker — the caller has already
        // decided, and a one-option control is just noise.
        if allowedScopes.count > 1 {
            DetailSection(title: "How long?") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Scope", selection: $scope) {
                        ForEach(allowedScopes) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(scope.explanation)
                        .font(.caption)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        if isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding alternatives...")
                    .font(.subheadline)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
        } else if loadFailed {
            // A failed request is NOT "no alternatives". Reporting it as one
            // sent the user off widening an equipment filter that was never
            // the problem.
            ContentUnavailableView {
                Label("Couldn't load alternatives", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") {
                    Task { await reload() }
                }
                .buttonStyle(.borderedProminent)
                .tint(MyoColor.Action.primary.color)
                .foregroundStyle(MyoColor.Text.primary.color)
            }
        } else if options.isEmpty {
            ContentUnavailableView {
                Label("No alternatives", systemImage: "arrow.triangle.swap")
            } description: {
                Text(
                    bodyweightOnly || !selectedEquipment.isEmpty
                        ? "Nothing matches with that equipment. Try widening the filter."
                        : "MYO has no substitute for this movement yet. Ask your coach in chat."
                )
            }
        } else {
            VStack(spacing: 10) {
                ForEach(options) { option in
                    optionRow(option)
                }
            }
        }
    }

    private func optionRow(_ option: ExerciseSwapOption) -> some View {
        Button {
            Task { await apply(option) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(option.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(MyoTheme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(option.reason)
                        .font(.caption)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(weightLine(for: option))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }

                Spacer(minLength: 8)

                if applyingOption == option.name {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.subheadline)
                        .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MyoTheme.Colors.cream)
            .overlay {
                RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                    .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(applyingOption != nil)
    }

    private func weightLine(for option: ExerciseSwapOption) -> String {
        if option.suggestedWeightLb <= 0 {
            return "Bodyweight — or set your own weight"
        }
        return option.weightFromBaseline
            ? "\(Int(option.suggestedWeightLb)) lb · your usual"
            : "Starting at \(Int(option.suggestedWeightLb)) lb"
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        let outcome = await appModel.fetchSwapOptions(
            exerciseName: exerciseName,
            dayKey: dayKey,
            sessionId: sessionId,
            availableEquipment: requestedEquipment
        )
        switch outcome {
        case .loaded(let loaded):
            options = loaded
            loadFailed = false
        case .failed:
            options = []
            loadFailed = true
        }
    }

    /// nil means "no constraint". An empty array means "I have nothing" —
    /// a different, deliberate answer the server treats as bodyweight-only.
    private var requestedEquipment: [String]? {
        if bodyweightOnly { return [] }
        if selectedEquipment.isEmpty { return nil }
        return Array(selectedEquipment)
    }

    private func apply(_ option: ExerciseSwapOption) async {
        applyingOption = option.name
        failureMessage = nil
        defer { applyingOption = nil }

        let failure = await appModel.swapExercise(
            dayKey: dayKey,
            exerciseName: exerciseName,
            replacementName: option.name,
            scope: scope,
            sessionId: scope == .session ? sessionId : nil
        )
        guard failure == nil else {
            failureMessage = failure
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

/// Shown after a workout, listing weights the user worked at that differ from
/// what was prescribed. Nothing is written until Apply — the coach's protocol
/// then continues from whatever number is confirmed here.
struct BaselineUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel

    let suggestions: [BaselineSuggestion]
    @State private var accepted: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Update your baselines?")
                            .font(.title2.bold())

                        Text("You worked at a different weight than planned. Applying this starts you here next time, and any weekly increase carries on from the new number.")
                            .font(.subheadline)
                            .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        ForEach(suggestions) { suggestion in
                            row(suggestion)
                        }
                    }

                    actions
                }
                .padding()
            }
            .background(MyoTheme.Colors.cream.ignoresSafeArea())
            .navigationTitle("Workout Complete")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            // Every suggestion starts checked: the user already made this
            // decision once, with the weight in their hands.
            accepted = Set(suggestions.map(\.exerciseName))
        }
    }

    private func row(_ suggestion: BaselineSuggestion) -> some View {
        Button {
            if accepted.contains(suggestion.exerciseName) {
                accepted.remove(suggestion.exerciseName)
            } else {
                accepted.insert(suggestion.exerciseName)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: accepted.contains(suggestion.exerciseName) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        accepted.contains(suggestion.exerciseName)
                            ? MyoTheme.Colors.ochre
                            : MyoTheme.Colors.ink.opacity(0.45)
                    )

                Text(suggestion.exerciseName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MyoTheme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text("\(Int(suggestion.fromLb)) → \(Int(suggestion.toLb)) lb")
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.75))
            }
            .padding()
            .background(MyoTheme.Colors.cream)
            .overlay {
                RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                    .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(suggestion.exerciseName), \(Int(suggestion.fromLb)) to \(Int(suggestion.toLb)) pounds"
        )
        .accessibilityAddTraits(accepted.contains(suggestion.exerciseName) ? [.isSelected] : [])
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                let chosen = suggestions.filter { accepted.contains($0.exerciseName) }
                Task {
                    await appModel.applyBaselineSuggestions(chosen)
                    dismiss()
                }
            } label: {
                Label(appModel.isWorkoutBusy ? "Applying..." : "Apply", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(MyoColor.Action.primary.color)
            .foregroundStyle(MyoColor.Text.primary.color)
            .disabled(accepted.isEmpty || appModel.isWorkoutBusy)

            Button("Not now") {
                appModel.dismissBaselineSuggestions()
                dismiss()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            .disabled(appModel.isWorkoutBusy)
        }
    }
}

private struct ExerciseSequencePlayer: View {
    let sequence: ExerciseSequence
    @State private var selectedIndex = 0
    @State private var isLooping = false

    private let timer = Timer.publish(every: 1.15, on: .main, in: .common).autoconnect()
    private let paperColor = MyoTheme.Colors.cream

    private var selectedFrame: ExerciseSequenceFrame {
        sequence.frames[min(selectedIndex, max(sequence.frames.count - 1, 0))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            sequenceImage

            Text(selectedFrame.cue)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            HStack(spacing: 8) {
                ForEach(sequence.frames.indices, id: \.self) { index in
                    Button {
                        withAnimation(MyoTheme.Motion.fade) {
                            selectedIndex = index
                            isLooping = false
                        }
                    } label: {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.black))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(index == selectedIndex ? MyoTheme.Colors.ochreLight : MyoTheme.Colors.ink.opacity(0.06))
                    .foregroundStyle(MyoTheme.Colors.ink)
                    .accessibilityLabel("\(sequence.frames[index].title) frame")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(paperColor)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
        .onReceive(timer) { _ in
            guard isLooping, !sequence.frames.isEmpty else {
                return
            }
            withAnimation(MyoTheme.Motion.fade) {
                selectedIndex = (selectedIndex + 1) % sequence.frames.count
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Movement Sequence")
                    .font(MyoTheme.Typography.monoLabel)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                    .textCase(.uppercase)

                Text(selectedFrame.title)
                    .font(.title3.bold())
            }

            Spacer()

            Button {
                isLooping.toggle()
            } label: {
                Label(isLooping ? "Pause" : "Loop", systemImage: isLooping ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(isLooping ? MyoTheme.Colors.ink : MyoTheme.Colors.ochreLight)
            .foregroundStyle(isLooping ? MyoTheme.Colors.cream : MyoTheme.Colors.ink)
            .accessibilityLabel(isLooping ? "Pause movement sequence" : "Loop movement sequence")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var sequenceImage: some View {
        if let image = loadImage(for: selectedFrame) {
            ZStack {
                paperColor

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 390)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(MyoTheme.Colors.ink.opacity(0.05))
                    .frame(height: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(MyoTheme.Colors.ink.opacity(0.05))
                    .frame(height: 1)
            }
        } else {
            ContentUnavailableView("Sequence image missing", systemImage: "photo", description: Text(selectedFrame.imageName))
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .background(paperColor)
        }
    }

    private func loadImage(for frame: ExerciseSequenceFrame) -> UIImage? {
        UIImage(named: frame.imageName)
    }
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(MyoTheme.Colors.ochre)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(MyoTheme.Typography.monoLabel)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MyoTheme.Typography.monoLabel)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
                .textCase(.uppercase)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(MyoTheme.Colors.cream)
        .overlay {
            RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous)
                .stroke(MyoTheme.Colors.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: MyoTheme.Radius.card, style: .continuous))
    }
}

private struct MuscleChipGroup: View {
    let title: String
    let muscles: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

            if muscles.isEmpty {
                Text("None listed")
                    .font(.subheadline)
                    .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(muscles, id: \.self) { muscle in
                        Text(muscle)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(tint.opacity(0.18))
                            .foregroundStyle(MyoTheme.Colors.ink)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

/// The weight actually being lifted for an exercise, mid-session.
///
/// Deliberately a stepper plus a tap-to-type field rather than chat: asking a
/// coach to change a number is worse than typing the number, and the old
/// "Change weight" quick-ask sent the user into a plan-adjustment flow that
/// could not apply. Steps in 5s because that is what plates come in; the field
/// accepts anything for dumbbells and machines that don't.
struct WorkoutWeightStepper: View {
    let weight: Double
    let isPrescribed: Bool
    let onChange: (Double) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private static let step: Double = 5

    var body: some View {
        HStack(spacing: 10) {
            Text("Weight")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MyoTheme.Colors.ink.opacity(0.65))

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onChange(max(0, weight - Self.step))
            } label: {
                Image(systemName: "minus")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(weight <= 0)
            .accessibilityLabel("Decrease weight by 5 pounds")

            if isEditing {
                TextField("lb", text: $draft)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .frame(minWidth: 68)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Button {
                    draft = weight == weight.rounded() ? String(Int(weight)) : String(weight)
                    isEditing = true
                    fieldFocused = true
                } label: {
                    Text("\(Int(weight)) lb")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .frame(minWidth: 68, minHeight: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Weight \(Int(weight)) pounds. Double tap to type an exact value.")
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onChange(weight + Self.step)
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Increase weight by 5 pounds")
        }
        .overlay(alignment: .bottomLeading) {
            // Only shown once the user has moved off the prescription, so the
            // default state stays quiet.
            if !isPrescribed {
                Text("adjusted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MyoTheme.Colors.ochre)
                    .offset(y: 14)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }

    private func commit() {
        isEditing = false
        // An unparseable entry keeps the previous value rather than zeroing
        // the set — a silent 0 would be logged as a real lift.
        guard let parsed = Double(draft.replacingOccurrences(of: ",", with: ".")) else { return }
        onChange(parsed)
    }
}

#Preview {
    WorkoutView()
        .environmentObject(AppModel())
}

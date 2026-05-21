import SwiftUI
import UIKit

struct WorkoutView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedDemoExercise: PlannedExercise?

    var body: some View {
        NavigationStack {
            Group {
                if appModel.user == nil {
                    signedOutView
                } else if let workout = appModel.activeWorkout {
                    ActiveWorkoutView(workout: workout)
                } else {
                    planView
                }
            }
            .navigationTitle("Workout")
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
            .tint(.black)
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
        .background(Color.myoIllustrationPaper.ignoresSafeArea())
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
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Try the Movement Sequence")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Preview the illustrated kettlebell swing frames.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.myoIllustrationPaper)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .foregroundStyle(.secondary)
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
            .tint(.yellow)
            .foregroundStyle(.black)
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
                    .foregroundStyle(.secondary)
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
                withAnimation(.snappy) {
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
                                .background(Color.yellow)
                                .foregroundStyle(.black)
                                .clipShape(Capsule())
                        }
                    }
                    .frame(width: 54)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(summaryText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.headline)
                        .foregroundStyle(.secondary)
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
                                    .background(Color.yellow.opacity(0.18))
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
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer()

                                Text(targetText(for: exercise))
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.secondary)

                                Image(systemName: "info.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
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
                    .tint(.yellow)
                    .foregroundStyle(.black)
                    .disabled(isBusy)
                    .padding(.top, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(Color.myoIllustrationPaper)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    musclesSection
                    cuesSection
                    askCoachSection
                    videoButton
                }
                .padding()
            }
            .background(Color.myoIllustrationPaper.ignoresSafeArea())
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exercise.name)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .minimumScaleFactor(0.72)

            Text(detailSubtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
                MuscleChipGroup(title: "Primary", muscles: knowledge.primary, tint: .yellow)
                MuscleChipGroup(title: "Secondary", muscles: knowledge.secondary, tint: .blue)
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
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                            .background(Color.yellow)
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
        .tint(.red)
    }

    private var askCoachSection: some View {
        DetailSection(title: "Ask MYO") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Ask for a swap, weight change, or better demo", text: $coachRequest, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                HStack(spacing: 8) {
                    quickAskButton("Change weight", request: "I need to change this exercise weight.")
                    quickAskButton("Better demo", request: "Can you find me a better picture or demo for this exercise?")
                }

                FlowLayout(spacing: 8) {
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
                    Label(appModel.isSending ? "Sending..." : "Send to MYO", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
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
        if let videoId = knowledge.youtubeVideoId {
            return URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
        }

        let query = "\(exercise.name) exercise form tutorial"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? exercise.name
        return URL(string: "https://www.youtube.com/results?search_query=\(query)")!
    }
}

private struct ActiveWorkoutView: View {
    @EnvironmentObject private var appModel: AppModel
    let workout: ActiveWorkoutSession
    @State private var selectedExercise: ActiveWorkoutExercise?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                ForEach(workout.exercises) { exercise in
                    WorkoutExerciseCard(exercise: exercise) {
                        selectedExercise = exercise
                    }
                }

                Button {
                    Task {
                        await appModel.finishActiveWorkout()
                    }
                } label: {
                    Label(appModel.isWorkoutBusy ? "Finishing..." : "Finish Workout", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(appModel.isWorkoutBusy)
                .padding(.top, 8)
            }
            .padding()
        }
        .sheet(item: $selectedExercise) { exercise in
            ExerciseDetailSheet(exercise: exercise)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workout.dayKey)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(workout.workoutName)
                .font(.largeTitle.bold())

            Text("\(completedSets)/\(totalSets) sets complete")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ProgressView(value: Double(completedSets), total: Double(max(totalSets, 1)))
                .tint(.yellow)
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

    var body: some View {
        Button(action: showDetails) {
            VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(targetText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appModel.toggleExerciseDone(exerciseIndex: exercise.exerciseIndex)
                } label: {
                    Image(systemName: exercise.exerciseDone ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(exercise.exerciseDone ? .green : .secondary)
                }
                .accessibilityLabel(exercise.exerciseDone ? "Mark exercise not done" : "Mark exercise done")
            }

            HStack(spacing: 8) {
                ForEach(exercise.completedSets) { set in
                    Button {
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
                    .tint(set.completed ? .green : Color(.tertiarySystemFill))
                    .foregroundStyle(set.completed ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Toggle set \(set.setIndex + 1)")
                }

                Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 48)
            }
        }
        .padding()
        .background(Color.myoIllustrationPaper)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    musclesSection
                    cuesSection
                    videoButton
                }
                .padding()
            }
            .background(Color.myoIllustrationPaper.ignoresSafeArea())
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exercise.name)
                .font(.largeTitle.bold())
                .lineLimit(3)
                .minimumScaleFactor(0.72)

            Text(detailSubtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
                MuscleChipGroup(title: "Primary", muscles: knowledge.primary, tint: .yellow)
                MuscleChipGroup(title: "Secondary", muscles: knowledge.secondary, tint: .blue)
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
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                            .background(Color.yellow)
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
        .tint(.red)
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
        if let videoId = knowledge.youtubeVideoId {
            return URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
        }

        let query = "\(exercise.name) exercise form tutorial"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? exercise.name
        return URL(string: "https://www.youtube.com/results?search_query=\(query)")!
    }
}

private struct ExerciseSequencePlayer: View {
    let sequence: ExerciseSequence
    @State private var selectedIndex = 0
    @State private var isLooping = false

    private let timer = Timer.publish(every: 1.15, on: .main, in: .common).autoconnect()
    private let paperColor = Color.myoIllustrationPaper

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
                        withAnimation(.snappy) {
                            selectedIndex = index
                            isLooping = false
                        }
                    } label: {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.black))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(index == selectedIndex ? .yellow : Color(.tertiarySystemFill))
                    .foregroundStyle(index == selectedIndex ? .black : .primary)
                    .accessibilityLabel("\(sequence.frames[index].title) frame")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(paperColor)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onReceive(timer) { _ in
            guard isLooping, !sequence.frames.isEmpty else {
                return
            }
            withAnimation(.snappy) {
                selectedIndex = (selectedIndex + 1) % sequence.frames.count
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Movement Sequence")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
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
            .tint(isLooping ? .black : .yellow)
            .foregroundStyle(isLooping ? .white : .black)
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
                    .fill(Color.black.opacity(0.05))
                    .frame(height: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(0.05))
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

extension Color {
    /// Sampled by Deter from the approved kettlebell illustration edge fields.
    static let myoIllustrationPaper = Color(red: 0.990, green: 0.957, blue: 0.912)
}

private struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.myoIllustrationPaper)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.myoIllustrationPaper)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .foregroundStyle(.secondary)

            if muscles.isEmpty {
                Text("None listed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(muscles, id: \.self) { muscle in
                        Text(muscle)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(tint.opacity(0.18))
                            .foregroundStyle(.primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview {
    WorkoutView()
        .environmentObject(AppModel())
}

import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import SwiftUI

@MainActor
final class AppModel: NSObject, ObservableObject {
    enum AppTab: Hashable {
        case coach
        case workout
        case progress
    }

    @Published private(set) var user: User?
    @Published private(set) var messages: [CoachMessage] = []
    @Published private(set) var onboardingMessages: [CoachMessage] = []
    @Published private(set) var onboardingStatus: OnboardingStatus = .notStarted
    @Published private(set) var onboardingStep: String = "goals"
    @Published private(set) var onboardingMissingFields: [String] = []
    @Published private(set) var pendingProgramProposal: ProgramProposalSummary?
    @Published private(set) var pendingPlanAdjustmentProposal: PlanAdjustmentProposalSummary?
    @Published private(set) var currentWorkoutPlan: WorkoutPlanSummary?
    @Published private(set) var activeWorkout: ActiveWorkoutSession?
    @Published private(set) var isSending = false
    @Published private(set) var isOnboardingBusy = false
    @Published private(set) var isWorkoutBusy = false
    @Published var selectedTab: AppTab = .coach
    @Published var errorMessage: String?

    private let sessionId = "general"
    // Resolved from Info.plist's `IronBoiCallableBaseURL` key, which is set
    // per build configuration in project.yml:
    //   Debug   → ironboi-staging cloudfunctions
    //   Release → ironboi-prod cloudfunctions
    // If the Info.plist value is missing or malformed (corrupted build,
    // unit test target), we log and fall back to staging so the app keeps
    // working instead of crashing on launch. The fallback is a literal
    // checked at build time, so the trailing `!` is safe.
    private let callableBaseURL: URL = AppModel.resolveCallableBaseURL()

    private static func resolveCallableBaseURL() -> URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "IronBoiCallableBaseURL") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let url = URL(string: trimmed) {
                return url
            }
        }
        // Debug: log and fall back to staging so the dev loop keeps working
        // if project.yml is being edited.
        // Release: fail loud. Silently routing TestFlight or App Store users
        // to staging would be a real-world data + auth leak, so we want
        // the build pipeline to halt at first launch instead.
        #if DEBUG
        NSLog("[IronBoi] Info.plist missing or invalid IronBoiCallableBaseURL — falling back to staging (Debug).")
        return URL(string: "https://us-central1-ironboi-staging.cloudfunctions.net")!
        #else
        fatalError("Info.plist is missing IronBoiCallableBaseURL for a non-Debug build — check project.yml's Release configuration before shipping.")
        #endif
    }

    private lazy var db = Firestore.firestore()
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var messageListener: ListenerRegistration?
    private var onboardingMessageListener: ListenerRegistration?
    private var profileListener: ListenerRegistration?
    private var proposalListener: ListenerRegistration?
    private var planAdjustmentProposalListener: ListenerRegistration?
    private var workoutPlanListener: ListenerRegistration?
    private var activeWorkoutListener: ListenerRegistration?
    private var currentNonce: String?

    deinit {
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
        messageListener?.remove()
        onboardingMessageListener?.remove()
        profileListener?.remove()
        proposalListener?.remove()
        planAdjustmentProposalListener?.remove()
        workoutPlanListener?.remove()
        activeWorkoutListener?.remove()
    }

    func start() {
        guard authHandle == nil else { return }

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                self?.listenForCoachMessages(userId: user?.uid)
                self?.listenForOnboardingState(userId: user?.uid)
                self?.listenForOnboardingMessages(userId: user?.uid)
                self?.listenForPendingProposal(userId: user?.uid)
                self?.listenForPendingPlanAdjustmentProposal(userId: user?.uid)
                self?.listenForCurrentWorkoutPlan(userId: user?.uid)
                self?.listenForActiveWorkout(userId: user?.uid)
            }
        }
    }

    func signInWithApple() {
        let nonce = Self.randomNonceString()
        currentNonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Phase 3 Task 3.1 — Account deletion.
    //
    // Calls the backend's `deleteAccount` onCall via the Firebase
    // Functions SDK. The SDK automatically attaches the App Check token
    // (Phase 3.2) and the Firebase Auth ID token. The backend tombstones
    // the account at deletedAccounts/{uid}, recursively wipes
    // users/{uid}/**, then revokes refresh tokens so any other
    // signed-in sessions can't keep making calls.
    //
    // After backend success we signOut locally — that triggers the auth
    // state listener which clears all subscriptions + cached state.
    //
    // Required by Apple App Store guideline 5.1.1(v).
    func deleteAccount() async {
        guard !isOnboardingBusy else { return }
        isOnboardingBusy = true
        defer { isOnboardingBusy = false }

        do {
            let functions = Functions.functions(region: "us-central1")
            let callable = functions.httpsCallable("deleteAccount")
            _ = try await callable.call([:] as [String: Any])
            // Server wipe succeeded — locally drop the session. The auth
            // state listener attached in start() will fire user=nil and
            // tear down listeners + clear cached state.
            try? Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetMyData() async {
        guard !isOnboardingBusy else { return }
        isOnboardingBusy = true
        defer { isOnboardingBusy = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()
            try await callFunction("resetMyDataHttp", idToken: idToken, data: [:])
            onboardingMessages = []
            messages = []
            onboardingStatus = .notStarted
            onboardingStep = "goals"
            onboardingMissingFields = []
            pendingProgramProposal = nil
            pendingPlanAdjustmentProposal = nil
            currentWorkoutPlan = nil
            activeWorkout = nil
            selectedTab = .coach
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendCoachMessage(
        _ content: String,
        structuredAnswer: [String: Any]? = nil
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()

            let now = ISO8601DateFormatter().string(from: Date())
            try await callFunction("sendCoachMessageHttp", idToken: idToken, data: [
                "sessionId": sessionId,
                "messageId": "ios_\(Int(Date().timeIntervalSince1970 * 1000))",
                "content": trimmed,
                "timestamp": now,
                "startedAt": now,
                "toolCallIds": [],
                "structuredAnswer": structuredAnswer ?? [:],
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func askCoachAboutWorkout(
        dayKey: String,
        exercise: PlannedExercise,
        request: String
    ) async {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let context = [
            "kind": "workout_plan_adjustment",
            "dayKey": dayKey,
            "exerciseName": exercise.name,
            "currentSets": exercise.sets,
            "currentReps": exercise.reps,
            "currentWeight": exercise.weight,
        ] as [String: Any]
        let message = """
        Workout context: \(dayKey), \(exercise.name), currently \(exercise.sets)x\(exercise.reps)\(exercise.weight > 0 ? " at \(Int(exercise.weight)) lb" : " bodyweight").

        \(trimmed)
        """

        await sendCoachMessage(message, structuredAnswer: context)
        selectedTab = .coach
    }

    func sendOnboardingAnswer(
        _ content: String,
        inputMode: CoachInputMode,
        structuredAnswer: [String: Any]? = nil
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || structuredAnswer?.isEmpty == false else { return }
        guard !isOnboardingBusy else { return }

        isOnboardingBusy = true
        defer { isOnboardingBusy = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()
            let now = Self.isoString(from: Date())
            try await callFunction("sendOnboardingAnswerHttp", idToken: idToken, data: [
                "messageId": "ios_onboarding_\(Int(Date().timeIntervalSince1970 * 1000))",
                "content": trimmed,
                "timestamp": now,
                "inputMode": inputMode.rawValue,
                "structuredAnswer": structuredAnswer ?? [:],
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptPendingProgramProposal() async {
        guard !isOnboardingBusy, let pendingProgramProposal else { return }

        isOnboardingBusy = true
        defer { isOnboardingBusy = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()
            try await callFunction("acceptProgramProposalHttp", idToken: idToken, data: [
                "proposalId": pendingProgramProposal.proposalId,
                "decidedAt": Self.isoString(from: Date()),
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptPendingPlanAdjustmentProposal() async {
        guard !isSending, let pendingPlanAdjustmentProposal else { return }

        isSending = true
        defer { isSending = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()
            try await callFunction("acceptPlanAdjustmentProposalHttp", idToken: idToken, data: [
                "proposalId": pendingPlanAdjustmentProposal.proposalId,
                "decidedAt": Self.isoString(from: Date()),
            ])
            try await refreshCurrentWorkoutPlan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startTodaysWorkout() async {
        await startWorkout(dayKey: Self.currentDayKey())
    }

    func startWorkout(dayKey: String) async {
        guard !isWorkoutBusy else { return }
        isWorkoutBusy = true
        defer { isWorkoutBusy = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()
            let now = Self.isoString(from: Date())
            let response: StartWorkoutResponse = try await callFunction(
                "startWorkoutSessionHttp",
                idToken: idToken,
                data: [
                    "dayKey": dayKey,
                    "startedAt": now,
                ]
            )
            activeWorkout = response.activeWorkout
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleWorkoutSet(exerciseIndex: Int, setIndex: Int) {
        guard var workout = activeWorkout,
              workout.exercises.indices.contains(exerciseIndex),
              workout.exercises[exerciseIndex].completedSets.indices.contains(setIndex)
        else { return }

        workout.exercises[exerciseIndex].completedSets[setIndex].completed.toggle()
        let allSetsDone = workout.exercises[exerciseIndex].completedSets.allSatisfy(\.completed)
        workout.exercises[exerciseIndex].exerciseDone = allSetsDone
        workout.updatedAt = Self.isoString(from: Date())
        activeWorkout = workout
    }

    func toggleExerciseDone(exerciseIndex: Int) {
        guard var workout = activeWorkout,
              workout.exercises.indices.contains(exerciseIndex)
        else { return }

        workout.exercises[exerciseIndex].exerciseDone.toggle()
        if workout.exercises[exerciseIndex].exerciseDone {
            workout.exercises[exerciseIndex].completedSets = workout.exercises[exerciseIndex].completedSets.map { set in
                var next = set
                next.completed = true
                return next
            }
        }
        workout.updatedAt = Self.isoString(from: Date())
        activeWorkout = workout
    }

    func finishActiveWorkout() async {
        guard !isWorkoutBusy, let activeWorkout else { return }
        isWorkoutBusy = true
        defer { isWorkoutBusy = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()
            let completedAt = Self.isoString(from: Date())
            let response: FinishWorkoutResponse = try await callFunction(
                "finishWorkoutSessionHttp",
                idToken: idToken,
                data: [
                    "sessionId": activeWorkout.sessionId,
                    "completedAt": completedAt,
                    "exercises": try Self.jsonObject(from: activeWorkout.exercises),
                ]
            )
            self.activeWorkout = response.activeWorkout.status == .active ? response.activeWorkout : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requireFreshFirebaseAuthToken() async throws -> String {
        guard let currentUser = Auth.auth().currentUser else {
            throw CoachAuthError.missingFirebaseUser
        }

        let idToken = try await currentUser.getIDToken(forcingRefresh: true)
        user = currentUser
        return idToken
    }

    private func callFunction(_ name: String, idToken: String, data: [String: Any]) async throws {
        let _: EmptyFunctionResponse = try await callFunction(name, idToken: idToken, data: data)
    }

    private func callFunction<T: Decodable>(_ name: String, idToken: String, data: [String: Any]) async throws -> T {
        var request = URLRequest(url: callableBaseURL.appendingPathComponent(name))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": data])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoachAuthError.invalidFunctionResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw CoachAuthError.functionFailed(Self.makeFunctionErrorMessage(from: responseData, statusCode: httpResponse.statusCode))
        }

        return try JSONDecoder().decode(T.self, from: responseData)
    }

    private func refreshCurrentWorkoutPlan() async throws {
        guard let userId = user?.uid else { return }
        let snapshot = try await db
            .collection("users")
            .document(userId)
            .collection("workoutPlans")
            .document("current")
            .getDocument()

        guard let data = snapshot.data() else {
            currentWorkoutPlan = nil
            return
        }

        currentWorkoutPlan = Self.makeWorkoutPlanSummary(from: data)
    }

    private static func makeFunctionErrorMessage(from data: Data, statusCode: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Coach request failed with HTTP \(statusCode)."
        }

        if let error = json["error"] as? [String: Any] {
            let status = error["status"] as? String
            let message = error["message"] as? String
            return [status, message].compactMap { $0 }.joined(separator: ": ")
        }

        if let error = json["error"] as? String {
            return error
        }

        return "Coach request failed with HTTP \(statusCode)."
    }

    private func listenForCoachMessages(userId: String?) {
        messageListener?.remove()
        messages = []

        guard let userId else { return }

        messageListener = db
            .collection("users")
            .document(userId)
            .collection("coachSessions")
            .document(sessionId)
            .collection("messages")
            .order(by: "serverCreatedAt", descending: false)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }

                    self?.messages = snapshot?.documents.compactMap(Self.makeCoachMessage) ?? []
                }
            }
    }

    private func listenForOnboardingState(userId: String?) {
        profileListener?.remove()
        onboardingStatus = .notStarted
        onboardingStep = "goals"
        onboardingMissingFields = []

        guard let userId else { return }

        profileListener = db
            .collection("users")
            .document(userId)
            .collection("profile")
            .document("current")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }

                    let data = snapshot?.data() ?? [:]
                    let rawStatus = data["onboardingStatus"] as? String ?? "not_started"
                    self?.onboardingStatus = OnboardingStatus(rawValue: rawStatus) ?? .notStarted
                    self?.onboardingStep = data["onboardingStep"] as? String ?? "goals"
                    self?.onboardingMissingFields = data["onboardingMissingFields"] as? [String] ?? []
                }
            }
    }

    private func listenForOnboardingMessages(userId: String?) {
        onboardingMessageListener?.remove()
        onboardingMessages = []

        guard let userId else { return }

        onboardingMessageListener = db
            .collection("users")
            .document(userId)
            .collection("coachSessions")
            .document("onboarding")
            .collection("messages")
            .order(by: "serverCreatedAt", descending: false)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }

                    self?.onboardingMessages = snapshot?.documents.compactMap(Self.makeCoachMessage) ?? []
                }
            }
    }

    private func listenForPendingProposal(userId: String?) {
        proposalListener?.remove()
        pendingProgramProposal = nil

        guard let userId else { return }

        proposalListener = db
            .collection("users")
            .document(userId)
            .collection("programProposals")
            .whereField("source", isEqualTo: "onboarding")
            .whereField("decision", isEqualTo: "pending")
            .limit(to: 1)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }

                    self?.pendingProgramProposal = snapshot?.documents.compactMap(Self.makeProgramProposalSummary).first
                }
            }
    }

    private func listenForPendingPlanAdjustmentProposal(userId: String?) {
        planAdjustmentProposalListener?.remove()
        pendingPlanAdjustmentProposal = nil

        guard let userId else { return }

        planAdjustmentProposalListener = db
            .collection("users")
            .document(userId)
            .collection("planAdjustmentProposals")
            .whereField("decision", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }

                    self?.pendingPlanAdjustmentProposal = snapshot?.documents
                        .compactMap(Self.makePlanAdjustmentProposalSummary)
                        .sorted(by: { $0.createdAt > $1.createdAt })
                        .first
                }
            }
    }

    private func listenForCurrentWorkoutPlan(userId: String?) {
        workoutPlanListener?.remove()
        currentWorkoutPlan = nil

        guard let userId else { return }

        workoutPlanListener = db
            .collection("users")
            .document(userId)
            .collection("workoutPlans")
            .document("current")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }

                    guard let data = snapshot?.data() else {
                        self?.currentWorkoutPlan = nil
                        return
                    }

                    self?.currentWorkoutPlan = Self.makeWorkoutPlanSummary(from: data)
                }
            }
    }

    private func listenForActiveWorkout(userId: String?) {
        activeWorkoutListener?.remove()
        activeWorkout = nil

        guard let userId else { return }

        activeWorkoutListener = db
            .collection("users")
            .document(userId)
            .collection("activeWorkout")
            .document("current")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }

                    guard let data = snapshot?.data(),
                          let workout = Self.makeActiveWorkout(from: data),
                          workout.status == .active
                    else {
                        self?.activeWorkout = nil
                        return
                    }

                    self?.activeWorkout = workout
                }
            }
    }

    private static func makeCoachMessage(from document: QueryDocumentSnapshot) -> CoachMessage {
        let data = document.data()
        let rawRole = data["role"] as? String ?? "coach"
        let rawStatus = data["status"] as? String ?? "unknown"
        let timestampString = data["timestamp"] as? String

        return CoachMessage(
            id: document.documentID,
            messageId: data["messageId"] as? String ?? document.documentID,
            role: CoachMessage.Role(rawValue: rawRole) ?? .coach,
            content: data["content"] as? String ?? "",
            status: CoachMessage.Status(rawValue: rawStatus) ?? .unknown,
            timestamp: timestampString.flatMap(Self.parseISODate) ?? Date(),
            riskLevel: data["riskLevel"] as? String
        )
    }

    private static func makeProgramProposalSummary(from document: QueryDocumentSnapshot) -> ProgramProposalSummary? {
        let data = document.data()
        guard
            let proposalId = data["proposalId"] as? String,
            let decision = data["decision"] as? String,
            let profile = data["profile"] as? [String: Any],
            let workoutPlan = data["workoutPlan"] as? [String: Any],
            let days = workoutPlan["days"] as? [String: Any],
            let nutritionTargets = data["nutritionTargets"] as? [String: Any]
        else { return nil }

        return ProgramProposalSummary(
            id: document.documentID,
            proposalId: proposalId,
            decision: decision,
            profile: makeProposalProfileSummary(from: profile),
            workoutDays: makeWorkoutDaySummaries(from: days),
            calories: makeRangeSummary(from: nutritionTargets["calories"]),
            proteinGrams: makeRangeSummary(from: nutritionTargets["proteinGrams"]),
            assumptions: nutritionTargets["assumptions"] as? [String] ?? [],
            safetyNotes: nutritionTargets["safetyNotes"] as? [String] ?? []
        )
    }

    private static func makePlanAdjustmentProposalSummary(from document: QueryDocumentSnapshot) -> PlanAdjustmentProposalSummary? {
        let data = document.data()
        guard
            let proposalId = data["proposalId"] as? String,
            let category = data["category"] as? String,
            let riskLevel = data["riskLevel"] as? String,
            let summary = data["summary"] as? String,
            let rationale = data["rationale"] as? String,
            let createdAt = data["createdAt"] as? String,
            let proposedPlanPatch = data["proposedPlanPatch"] as? [String: Any],
            let patchTitle = proposedPlanPatch["title"] as? String
        else { return nil }

        let appliesTo = data["appliesTo"] as? [String: Any]

        return PlanAdjustmentProposalSummary(
            id: document.documentID,
            proposalId: proposalId,
            category: category,
            riskLevel: riskLevel,
            summary: summary,
            rationale: rationale,
            dayKey: appliesTo?["dayKey"] as? String,
            patchTitle: patchTitle,
            changes: proposedPlanPatch["changes"] as? [String] ?? [],
            safetyNotes: data["safetyNotes"] as? [String] ?? [],
            sourceCorpusEntryIds: data["sourceCorpusEntryIds"] as? [String] ?? [],
            requiresFollowUp: data["requiresFollowUp"] as? Bool ?? false,
            createdAt: createdAt
        )
    }

    private static func makeProposalProfileSummary(from profile: [String: Any]) -> ProposalProfileSummary {
        let schedule = profile["schedule"] as? [String: Any] ?? [:]
        let preferences = profile["preferences"] as? [String: Any] ?? [:]
        return ProposalProfileSummary(
            goals: profile["goals"] as? [String] ?? [],
            ageYears: profile["ageYears"] as? Int,
            sexOrGender: profile["sexOrGender"] as? String,
            heightCm: makeDouble(from: profile["heightCm"]),
            weightKg: makeDouble(from: profile["weightKg"]),
            trainingExperience: profile["trainingExperience"] as? String,
            equipment: profile["equipment"] as? [String] ?? [],
            daysPerWeek: schedule["daysPerWeek"] as? Int,
            sessionLengthMin: schedule["sessionLengthMin"] as? Int,
            trainingFocus: preferences["trainingFocus"] as? String,
            injuriesOrLimitations: profile["injuriesOrLimitations"] as? [String] ?? [],
            dietaryConstraints: profile["dietaryConstraints"] as? [String] ?? []
        )
    }

    private static func makeDouble(from value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func makeWorkoutDaySummaries(from days: [String: Any]) -> [WorkoutDaySummary] {
        let dayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return dayOrder.compactMap { dayKey in
            guard let rawDay = days[dayKey] as? [String: Any],
                  let name = rawDay["name"] as? String
            else { return nil }

            let rawExercises = rawDay["exercises"] as? [[String: Any]] ?? []
            return WorkoutDaySummary(
                id: dayKey,
                dayKey: dayKey,
                name: name,
                exerciseNames: rawExercises.compactMap { $0["name"] as? String }
            )
        }
    }

    private static func makeRangeSummary(from value: Any?) -> RangeSummary? {
        guard let raw = value as? [String: Any] else { return nil }
        let minValue = raw["min"] as? Int ?? Int(raw["min"] as? Double ?? 0)
        let maxValue = raw["max"] as? Int ?? Int(raw["max"] as? Double ?? 0)
        guard minValue > 0, maxValue > 0 else { return nil }
        return RangeSummary(min: minValue, max: maxValue, note: raw["note"] as? String)
    }

    private static func makeWorkoutPlanSummary(from data: [String: Any]) -> WorkoutPlanSummary? {
        guard
            let userId = data["userId"] as? String,
            let planId = data["planId"] as? String,
            let days = data["days"] as? [String: Any]
        else { return nil }

        return WorkoutPlanSummary(
            userId: userId,
            planId: planId,
            source: data["source"] as? String ?? "coach_generated",
            updatedAt: data["updatedAt"] as? String ?? "",
            days: makePlannedWorkoutDays(from: days)
        )
    }

    private static func makePlannedWorkoutDays(from days: [String: Any]) -> [PlannedWorkoutDay] {
        let dayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return dayOrder.compactMap { dayKey in
            guard
                let rawDay = days[dayKey] as? [String: Any],
                let name = rawDay["name"] as? String
            else { return nil }

            let rawExercises = rawDay["exercises"] as? [[String: Any]] ?? []
            return PlannedWorkoutDay(
                dayKey: dayKey,
                name: name,
                muscles: rawDay["muscles"] as? [String] ?? [],
                exercises: rawExercises.compactMap(makePlannedExercise)
            )
        }
    }

    private static func makePlannedExercise(from raw: [String: Any]) -> PlannedExercise? {
        guard
            let name = raw["name"] as? String,
            let sets = raw["sets"] as? Int,
            let reps = raw["reps"] as? Int
        else { return nil }

        return PlannedExercise(
            name: name,
            sets: sets,
            reps: reps,
            weight: makeDouble(from: raw["weight"]) ?? 0
        )
    }

    private static func parseISODate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func currentDayKey() -> String {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday - 1]
    }

    private static func jsonObject<T: Encodable>(from value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func makeActiveWorkout(from data: [String: Any]) -> ActiveWorkoutSession? {
        guard
            let userId = data["userId"] as? String,
            let sessionId = data["sessionId"] as? String,
            let dayKey = data["dayKey"] as? String,
            let workoutName = data["workoutName"] as? String,
            let rawStatus = data["status"] as? String,
            let status = ActiveWorkoutSession.Status(rawValue: rawStatus),
            let startedAt = data["startedAt"] as? String,
            let updatedAt = data["updatedAt"] as? String
        else { return nil }

        return ActiveWorkoutSession(
            userId: userId,
            sessionId: sessionId,
            planId: data["planId"] as? String ?? "current",
            dayKey: dayKey,
            workoutName: workoutName,
            status: status,
            startedAt: startedAt,
            updatedAt: updatedAt,
            completedAt: data["completedAt"] as? String,
            exercises: makeActiveWorkoutExercises(from: data["exercises"])
        )
    }

    private static func makeActiveWorkoutExercises(from value: Any?) -> [ActiveWorkoutExercise] {
        guard let rawExercises = value as? [[String: Any]] else { return [] }
        return rawExercises.compactMap { raw in
            guard
                let exerciseIndex = raw["exerciseIndex"] as? Int,
                let name = raw["name"] as? String,
                let targetSets = raw["targetSets"] as? Int,
                let targetReps = raw["targetReps"] as? Int
            else { return nil }

            return ActiveWorkoutExercise(
                exerciseIndex: exerciseIndex,
                name: name,
                targetSets: targetSets,
                targetReps: targetReps,
                targetWeight: raw["targetWeight"] as? Double ?? 0,
                completedSets: makeActiveWorkoutSets(from: raw["completedSets"]),
                exerciseDone: raw["exerciseDone"] as? Bool ?? false,
                notes: raw["notes"] as? String
            )
        }
    }

    private static func makeActiveWorkoutSets(from value: Any?) -> [ActiveWorkoutSet] {
        guard let rawSets = value as? [[String: Any]] else { return [] }
        return rawSets.compactMap { raw in
            guard let setIndex = raw["setIndex"] as? Int else { return nil }
            return ActiveWorkoutSet(
                setIndex: setIndex,
                completed: raw["completed"] as? Bool ?? false,
                reps: raw["reps"] as? Int,
                weight: raw["weight"] as? Double
            )
        }
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            precondition(status == errSecSuccess)

            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }
}

private struct EmptyFunctionResponse: Decodable {}

private enum CoachAuthError: LocalizedError {
    case missingFirebaseUser
    case invalidFunctionResponse
    case functionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFirebaseUser:
            return "Firebase Auth is not ready yet. Sign out, sign back in, then try again."
        case .invalidFunctionResponse:
            return "Coach request failed before Firebase returned a response."
        case .functionFailed(let message):
            return message
        }
    }
}

extension AppModel: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let identityToken = appleCredential.identityToken,
            let identityTokenString = String(data: identityToken, encoding: .utf8)
        else {
            Task { @MainActor in
                self.errorMessage = "Unable to read Apple identity token."
            }
            return
        }

        Task { @MainActor in
            guard let currentNonce else {
                errorMessage = "Missing Apple sign-in nonce."
                return
            }

            let credential = OAuthProvider.appleCredential(
                withIDToken: identityTokenString,
                rawNonce: currentNonce,
                fullName: appleCredential.fullName
            )

            do {
                _ = try await Auth.auth().signIn(with: credential)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            self.errorMessage = error.localizedDescription
        }
    }
}

extension AppModel: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? UIWindow()
        }
    }
}

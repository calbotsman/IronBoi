import AuthenticationServices
import CryptoKit
import FirebaseAppCheck
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
        case you
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
    @Published private(set) var workoutLogs: [WorkoutLogSummary] = []
    @Published private(set) var profile: UserProfile = .empty
    @Published private(set) var isSending = false
    @Published private(set) var isOnboardingBusy = false
    @Published private(set) var isWorkoutBusy = false
    @Published private(set) var isSavingProfile = false
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
        // Always fall back to staging if the Info.plist lookup fails.
        //
        // Xcode's auto-generated Info.plist (GENERATE_INFOPLIST_FILE: YES)
        // only propagates INFOPLIST_KEY_* settings whose names match
        // Apple-defined keys. Our custom IronBoiCallableBaseURL doesn't
        // qualify, so the lookup returns nil and we end up here on every
        // build. Until we move to a real Info.plist or .xcconfig for
        // custom keys, the staging fallback keeps the app alive.
        //
        // SECURITY NOTE: Before shipping to the PUBLIC App Store (not
        // TestFlight), wire up a real prod URL via a hand-written
        // Info.plist or xcconfig per build configuration. Otherwise
        // public users will route to staging.
        NSLog("[IronBoi] Info.plist IronBoiCallableBaseURL is missing or invalid; using staging fallback.")
        return URL(string: "https://us-central1-ironboi-staging.cloudfunctions.net")!
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
    private var workoutLogListener: ListenerRegistration?
    // Raw workoutPlans/current doc — kept so the derived summary (which
    // bakes in "today's" dailyOverride) can be recomputed when the calendar
    // date changes without a server round-trip.
    private var latestWorkoutPlanData: [String: Any]?
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
        workoutLogListener?.remove()
    }

    func start() {
        guard authHandle == nil else { return }

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                #if DEBUG
                // In a local preview session, ignore auth events so the
                // listeners don't clear the seeded data back to empty.
                if self.isPreviewSession { return }
                #endif
                self.user = user
                self.listenForCoachMessages(userId: user?.uid)
                self.listenForOnboardingState(userId: user?.uid)
                self.listenForOnboardingMessages(userId: user?.uid)
                self.listenForPendingProposal(userId: user?.uid)
                self.listenForPendingPlanAdjustmentProposal(userId: user?.uid)
                self.listenForCurrentWorkoutPlan(userId: user?.uid)
                self.listenForActiveWorkout(userId: user?.uid)
                self.listenForWorkoutLogs(userId: user?.uid)
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

    #if DEBUG
    // Simulator-friendly sign-in. Apple Sign-In on a simulator requires an
    // Apple ID logged into the sim and fails often; anonymous auth gives a
    // real Firebase uid against staging so the full flow (onboarding, plan,
    // coach) is testable. Compiled out of Release builds entirely.
    // Requires Anonymous auth enabled on the staging Firebase project
    // (Console → Authentication → Sign-in method → Anonymous).
    func signInAsDeveloper() async {
        do {
            let result = try await Auth.auth().signInAnonymously()
            user = result.user
        } catch {
            errorMessage = "Dev sign-in failed: \(error.localizedDescription) — is Anonymous auth enabled on staging?"
        }
    }

    /// Local-only preview: seeds a complete session (profile, plan, coach
    /// thread, history) so every tab is explorable on the simulator with NO
    /// Firebase backend, auth, or console toggles. Reads as a session via
    /// `hasSession`. Nothing here touches the network. Release-stripped.
    @Published private(set) var isPreviewSession = false

    func startPreviewSession() {
        isPreviewSession = true
        onboardingStatus = .complete
        profile = Self.previewProfile
        currentWorkoutPlan = Self.previewPlan
        messages = Self.previewMessages
        workoutLogs = Self.previewLogs
    }
    #endif

    /// True when there's a usable session — a real Firebase user, or (DEBUG)
    /// the local preview. Views gate their populated states on this.
    var hasSession: Bool {
        #if DEBUG
        if isPreviewSession { return true }
        #endif
        return user != nil
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
                // Local calendar date — a chat-driven "yes, just today" keys
                // its override to the user's day, not the server timezone.
                "clientDate": Self.currentDateISO(),
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

    // scope: "today" | "rest_of_week" | "going_forward", or nil to use
    // whatever scope the proposal already carries (e.g. legacy proposals
    // with a single implicit target day).
    func acceptPendingPlanAdjustmentProposal(scope: String? = nil) async {
        guard !isSending, let pendingPlanAdjustmentProposal else { return }

        isSending = true
        defer { isSending = false }

        do {
            let idToken = try await requireFreshFirebaseAuthToken()
            var data: [String: Any] = [
                "proposalId": pendingPlanAdjustmentProposal.proposalId,
                "decidedAt": Self.isoString(from: Date()),
                // The user's local calendar date — the backend keys a
                // today-scope override to this, not to the server's timezone.
                "clientDate": Self.currentDateISO(),
            ]
            if let scope {
                data["scope"] = scope
            }
            try await callFunction("acceptPlanAdjustmentProposalHttp", idToken: idToken, data: data)
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
                    // Local calendar date — the backend uses it to resolve a
                    // "just today" dailyOverride for the day being started.
                    "clientDate": Self.currentDateISO(),
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

        // Non-forcing: the SDK returns the cached token and only round-trips to
        // Firebase when it's within ~5 min of expiry. Forcing a refresh on every
        // user action added latency and a failure point to each interaction.
        let idToken = try await currentUser.getIDToken()
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

        // This custom wrapper bypasses the Firebase SDK, so App Check tokens
        // don't attach automatically. Fetch one and send it in the header the
        // backend's verifyToken path expects (X-Firebase-AppCheck). Failure to
        // mint a token is non-fatal until the server enforces App Check on
        // the *Http endpoints — log and continue rather than block the user.
        do {
            let appCheckToken = try await AppCheck.appCheck().token(forcingRefresh: false)
            request.setValue(appCheckToken.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        } catch {
            NSLog("[IronBoi] App Check token unavailable for \(name): \(error.localizedDescription)")
        }

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
                    // Full profile struct — Preferences view reads from this
                    // and pre-fills its form fields.
                    self?.profile = UserProfile.from(firestoreData: data)
                }
            }
    }

    // MARK: - Preferences / profile editing

    /// Send the entire profile to the upsertProfile callable. The backend
    /// (`functions/src/index.ts:upsertProfile`) validates the payload with
    /// the UserHealthProfile Zod schema and writes to
    /// `users/{uid}/profile/current`. The profile listener picks up the
    /// change and republishes via @Published.
    func upsertProfile(_ next: UserProfile) async {
        guard !isSavingProfile else { return }
        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            // Resilient HTTP endpoint (auth-only), NOT the SDK callable. The
            // callable attaches an App Check token that's invalid on Debug
            // builds, and callables reject invalid tokens — which silently
            // broke every profile save on device. The *Http path checks auth.
            let idToken = try await requireFreshFirebaseAuthToken()
            try await callFunction("upsertProfileHttp", idToken: idToken, data: next.firestorePayload())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Server-side rebuild of the user's workoutPlans/current doc from
    /// their currently-saved profile. Used after editing days-per-week
    /// or preferredDays — the chat-based onboarding generates the plan
    /// the first time, this lets the user request a fresh one without
    /// re-running onboarding.
    func regenerateWorkoutPlan() async {
        guard !isWorkoutBusy else { return }
        isWorkoutBusy = true
        defer { isWorkoutBusy = false }

        do {
            // Resilient HTTP endpoint (auth-only), same reason as upsertProfile.
            let idToken = try await requireFreshFirebaseAuthToken()
            try await callFunction("regenerateWorkoutPlanHttp", idToken: idToken, data: [:])
            // The Firestore listener picks up the new plan and republishes
            // currentWorkoutPlan automatically — no local mutation needed.
        } catch {
            errorMessage = error.localizedDescription
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
                        self?.latestWorkoutPlanData = nil
                        self?.currentWorkoutPlan = nil
                        return
                    }

                    // Keep the raw doc: the summary bakes in "today's"
                    // dailyOverride, so it must be re-derivable when the
                    // date changes without waiting for a server write
                    // (see recomputeCurrentWorkoutPlanForToday).
                    self?.latestWorkoutPlanData = data
                    self?.currentWorkoutPlan = Self.makeWorkoutPlanSummary(from: data)
                }
            }
    }

    // Firestore only re-emits on server changes — an app that stays
    // resident across midnight would otherwise keep yesterday's override
    // spliced into the wrong day. Views call this on scenePhase
    // reactivation to re-derive the summary from the cached raw doc.
    func recomputeCurrentWorkoutPlanForToday() {
        guard let latestWorkoutPlanData else { return }
        currentWorkoutPlan = Self.makeWorkoutPlanSummary(from: latestWorkoutPlanData)
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

    private func listenForWorkoutLogs(userId: String?) {
        workoutLogListener?.remove()
        workoutLogs = []

        guard let userId else { return }

        workoutLogListener = db
            .collection("users")
            .document(userId)
            .collection("workoutLogs")
            .order(by: "date", descending: true)
            .limit(to: 60)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = error.localizedDescription
                        return
                    }
                    self?.workoutLogs = (snapshot?.documents ?? [])
                        .compactMap { Self.makeWorkoutLogSummary(from: $0.data()) }
                }
            }
    }

    private static func makeWorkoutLogSummary(from data: [String: Any]) -> WorkoutLogSummary? {
        guard let sessionId = data["sessionId"] as? String,
              let date = data["date"] as? String else { return nil }

        // postSessionNotes is written as "dayKey: workoutName" — take the name.
        let notes = (data["postSessionNotes"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let title: String
        if let range = notes.range(of: ": ") {
            title = String(notes[range.upperBound...])
        } else {
            title = notes.isEmpty ? "Workout" : notes
        }

        let exercises = (data["exercises"] as? [[String: Any]] ?? []).map { ex -> LoggedExercise in
            let sets = (ex["sets"] as? [[String: Any]] ?? []).map { set in
                LoggedSet(reps: set["reps"] as? Int, loadKg: set["loadKg"] as? Double)
            }
            return LoggedExercise(name: ex["name"] as? String ?? "Exercise", sets: sets)
        }

        return WorkoutLogSummary(
            sessionId: sessionId,
            date: date,
            title: title.isEmpty ? "Workout" : title,
            exercises: exercises,
            durationSec: data["durationSec"] as? Int,
            perceivedEffort: data["perceivedEffort"] as? Int
        )
    }

    private static func makeCoachMessage(from document: QueryDocumentSnapshot) -> CoachMessage {
        let data = document.data()
        let rawRole = data["role"] as? String ?? "coach"
        let rawStatus = data["status"] as? String ?? "unknown"
        let timestampString = data["timestamp"] as? String

        let sources = (data["sources"] as? [[String: Any]] ?? []).compactMap { raw -> CoachSource? in
            guard let entryId = raw["entryId"] as? String,
                  let label = raw["label"] as? String else { return nil }
            return CoachSource(
                entryId: entryId,
                label: label,
                title: raw["title"] as? String ?? label,
                url: (raw["sourceUrl"] as? String).flatMap(URL.init(string:))
            )
        }

        return CoachMessage(
            id: document.documentID,
            messageId: data["messageId"] as? String ?? document.documentID,
            role: CoachMessage.Role(rawValue: rawRole) ?? .coach,
            content: data["content"] as? String ?? "",
            status: CoachMessage.Status(rawValue: rawStatus) ?? .unknown,
            timestamp: timestampString.flatMap(Self.parseISODate) ?? Date(),
            riskLevel: data["riskLevel"] as? String,
            sources: sources
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
            createdAt: createdAt,
            scope: appliesTo?["scope"] as? String
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

        // Temporary plan adjustments land in dailyOverrides keyed by ISO
        // date rather than in `days` (keyed by weekday), so they never bleed
        // into the repeating week. Resolve EVERY weekday card through its
        // next occurrence's override (the same rule the backend uses when
        // starting a workout) — a Wednesday adjustment for Wed→Sun must be
        // visible on those cards, not just today's.
        let dailyOverrides = data["dailyOverrides"] as? [String: Any] ?? [:]
        var resolvedDays = days
        var adjustedDayKeys = Set<String>()
        let today = Self.currentDateISO()
        for dayKey in ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] {
            let overrideDate = Self.nextOccurrenceISO(of: dayKey, onOrAfter: today)
            if let override = dailyOverrides[overrideDate] {
                resolvedDays[dayKey] = override
                adjustedDayKeys.insert(dayKey)
            }
        }

        return WorkoutPlanSummary(
            userId: userId,
            planId: planId,
            source: data["source"] as? String ?? "coach_generated",
            updatedAt: data["updatedAt"] as? String ?? "",
            days: makePlannedWorkoutDays(from: resolvedDays, adjustedDayKeys: adjustedDayKeys)
        )
    }

    // ISO date (yyyy-MM-dd, Gregorian) of the next occurrence of `dayKey` on
    // or after the given local date — mirrors the backend's
    // nextOccurrenceOfWeekday so client and server agree on which override
    // a weekday card shows.
    private static func nextOccurrenceISO(of dayKey: String, onOrAfter isoDate: String) -> String {
        let order = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        guard let targetIndex = order.firstIndex(of: dayKey) else { return isoDate }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: isoDate) else { return isoDate }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startWeekday = calendar.component(.weekday, from: start) - 1 // Sun=0
        let daysAhead = (targetIndex - startWeekday + 7) % 7
        guard let target = calendar.date(byAdding: .day, value: daysAhead, to: start) else {
            return isoDate
        }
        return formatter.string(from: target)
    }

    private static func makePlannedWorkoutDays(
        from days: [String: Any],
        adjustedDayKeys: Set<String> = []
    ) -> [PlannedWorkoutDay] {
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
                exercises: rawExercises.compactMap(makePlannedExercise),
                isAdjusted: adjustedDayKeys.contains(dayKey)
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

    // Device-local calendar DATE (what day it is for the user), rendered as
    // a Gregorian/ISO string. The explicit iso8601 calendar + POSIX locale
    // matter: a device set to the Buddhist or Japanese calendar would
    // otherwise render e.g. 2569-07-14 and never match the backend's
    // Gregorian override keys. This value is also SENT to the backend
    // (clientDate) so override dates are keyed to the user's day, not the
    // server's timezone.
    private static func currentDateISO() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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

#if DEBUG
// MARK: - Preview seed data (DEBUG only, never networked)

extension AppModel {
    static var previewProfile: UserProfile {
        var p = UserProfile.empty
        p.ageYears = 32
        p.sexOrGender = .male
        p.heightCm = 180
        p.weightKg = 82
        p.goals = [.strength, .muscleGain]
        p.trainingExperience = .intermediate
        p.equipment = ["Barbell", "Dumbbells", "Pull-up bar"]
        p.injuriesOrLimitations = ["Left knee meniscus"]
        p.schedule.daysPerWeek = 4
        p.schedule.sessionLengthMin = 60
        p.preferences.coachingTone = .balanced
        p.preferences.trainingFocus = .strengthConditioning
        p.preferences.coachingLens = .huberman
        return p
    }

    static var previewPlan: WorkoutPlanSummary {
        WorkoutPlanSummary(
            userId: "preview",
            planId: "current",
            source: "preview",
            updatedAt: "2026-06-22",
            days: [
                PlannedWorkoutDay(dayKey: "Mon", name: "Lower Body Strength", muscles: ["Quads", "Glutes", "Hamstrings"], exercises: [
                    PlannedExercise(name: "Back Squat", sets: 5, reps: 5, weight: 225),
                    PlannedExercise(name: "Romanian Deadlift", sets: 3, reps: 8, weight: 185),
                    PlannedExercise(name: "Walking Lunge", sets: 3, reps: 12, weight: 40),
                ]),
                PlannedWorkoutDay(dayKey: "Wed", name: "Upper Push", muscles: ["Chest", "Shoulders", "Triceps"], exercises: [
                    PlannedExercise(name: "Bench Press", sets: 5, reps: 5, weight: 185),
                    PlannedExercise(name: "Overhead Press", sets: 4, reps: 6, weight: 110),
                    PlannedExercise(name: "Incline Dumbbell Press", sets: 3, reps: 10, weight: 60),
                ]),
                PlannedWorkoutDay(dayKey: "Fri", name: "Pull Day", muscles: ["Back", "Biceps"], exercises: [
                    PlannedExercise(name: "Deadlift", sets: 4, reps: 3, weight: 315),
                    PlannedExercise(name: "Pull-up", sets: 4, reps: 8, weight: 0),
                    PlannedExercise(name: "Barbell Row", sets: 3, reps: 10, weight: 155),
                ]),
            ]
        )
    }

    static var previewMessages: [CoachMessage] {
        let now = Date()
        return [
            CoachMessage(id: "m1", messageId: "m1", role: .user,
                content: "I only slept about 5 hours and my knee feels a little off. Should I still do legs today?",
                status: .complete, timestamp: now.addingTimeInterval(-600), riskLevel: nil),
            CoachMessage(id: "m2", messageId: "m2", role: .coach,
                content: "From a recovery-first view, let's pull it back today rather than push through. Drop the squat to 3 working sets and skip the lunges — your knee and your short sleep both point the same direction. We can make it up later in the week. (Schoenfeld: volume can be redistributed without losing the adaptation.)",
                status: .complete, timestamp: now.addingTimeInterval(-560), riskLevel: nil,
                sources: [
                    CoachSource(entryId: "protocol_huberman_recovery_v1",
                        label: "Sleep & athletic-performance literature (Huberman protocol)",
                        title: "Recovery, sleep, and circadian timing for training",
                        url: URL(string: "https://pubmed.ncbi.nlm.nih.gov/21731144/")),
                    CoachSource(entryId: "protocol_schoenfeld_hypertrophy_v1",
                        label: "Schoenfeld et al., peer-reviewed hypertrophy research",
                        title: "Hypertrophy mechanics: tension, volume, progression",
                        url: URL(string: "https://pubmed.ncbi.nlm.nih.gov/27433992/")),
                ]),
            CoachMessage(id: "m3", messageId: "m3", role: .user,
                content: "Okay that works. What should I watch for in the knee?",
                status: .complete, timestamp: now.addingTimeInterval(-300), riskLevel: nil),
            CoachMessage(id: "m4", messageId: "m4", role: .coach,
                content: "Stop the set if you feel sharp pain on the inside of the joint or any catching. A dull ache that fades as you warm up is usually fine. Keep the tempo controlled on the way down — that's where the meniscus complains most.",
                status: .complete, timestamp: now.addingTimeInterval(-260), riskLevel: nil,
                sources: [
                    CoachSource(entryId: "myo_pain_injury_adjustment_v1",
                        label: "MYO reviewed coaching note — pain & injury",
                        title: "Pain and injury workout adjustment rule",
                        url: nil),
                ]),
        ]
    }

    static var previewLogs: [WorkoutLogSummary] {
        [
            WorkoutLogSummary(sessionId: "p1", date: "2026-06-20", title: "Lower Body Strength",
                exercises: [
                    LoggedExercise(name: "Back Squat", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 102), count: 5)),
                    LoggedExercise(name: "Romanian Deadlift", sets: Array(repeating: LoggedSet(reps: 8, loadKg: 84), count: 3)),
                    LoggedExercise(name: "Walking Lunge", sets: Array(repeating: LoggedSet(reps: 12, loadKg: 20), count: 3)),
                ], durationSec: 3300, perceivedEffort: 7),
            WorkoutLogSummary(sessionId: "p2", date: "2026-06-18", title: "Upper Push",
                exercises: [
                    LoggedExercise(name: "Bench Press", sets: Array(repeating: LoggedSet(reps: 5, loadKg: 84), count: 5)),
                    LoggedExercise(name: "Overhead Press", sets: Array(repeating: LoggedSet(reps: 6, loadKg: 50), count: 4)),
                ], durationSec: 2700, perceivedEffort: 6),
            WorkoutLogSummary(sessionId: "p3", date: "2026-06-16", title: "Pull Day",
                exercises: [
                    LoggedExercise(name: "Deadlift", sets: Array(repeating: LoggedSet(reps: 3, loadKg: 140), count: 4)),
                    LoggedExercise(name: "Pull-up", sets: Array(repeating: LoggedSet(reps: 8, loadKg: nil), count: 4)),
                ], durationSec: 3000, perceivedEffort: 8),
        ]
    }
}
#endif

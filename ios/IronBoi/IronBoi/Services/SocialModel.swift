import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation

/// Social prototype — "train with friends". docs/product/social-prototype.md.
///
/// Two gates, both off by default:
///   1. `SocialFeature.isAvailable` (this build): false → nothing social is
///      ever drawn, asked or called. Flip `enabledInBuild`, or launch with
///      `-MYOSocialPrototype YES` in a Debug build.
///   2. The person's own answer: until they say yes, social is absent from
///      the app apart from one "Train with friends" row in the You tab.
/// The server has its own flag too (IRONBOI_SOCIAL_ENABLED).
enum SocialFeature {
    /// The switch Josh flips to ship the prototype to testers.
    static let enabledInBuild = false

    static var isAvailable: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MYOSocialPrototype") { return true }
        #endif
        return enabledInBuild
    }

    static let consentRecordId = "social_activity_v1"
    static let policyVersion = "2026-11-05-social"
}

struct SocialFriend: Decodable, Identifiable, Equatable {
    let friendId: String
    let firstName: String
    let trainedToday: Bool
    let streakWeeks: Int
    var id: String { friendId }
}

@MainActor
final class SocialModel: ObservableObject {
    static let shared = SocialModel()

    /// Social consent is granted (server record is the source of truth).
    @Published private(set) var isOn = false
    @Published private(set) var friends: [SocialFriend] = []
    @Published private(set) var invite: (code: String, link: String)?
    @Published var note: String?
    @Published private(set) var busy = false
    /// The one onboarding question, asked once per account.
    @Published var askOnboardingQuestion = false
    /// A code from a myo://join link, waiting for the You tab.
    @Published var pendingCode: String?

    private lazy var functions = Functions.functions(region: "us-central1")
    private var loadedFor: String?

    private func answeredKey(_ uid: String) -> String { "myo.social.answered.\(uid)" }

    /// Load consent for the signed-in user; decide whether to ask the question.
    func refresh(onboardingComplete: Bool) async {
        guard SocialFeature.isAvailable, let uid = Auth.auth().currentUser?.uid else { return }
        if loadedFor != uid {
            loadedFor = uid
            isOn = false
            friends = []
            invite = nil
        }
        let snap = try? await Firestore.firestore()
            .collection("users").document(uid)
            .collection("consentRecords").document(SocialFeature.consentRecordId)
            .getDocument()
        let data = snap?.data()
        isOn = (data?["granted"] as? Bool) == true && (data?["category"] as? String) == "social_activity"
        let answered = UserDefaults.standard.bool(forKey: answeredKey(uid)) || data != nil
        askOnboardingQuestion = onboardingComplete && !answered
        if isOn { await loadFriends() }
    }

    /// Onboarding answer. "Not now" just remembers it was asked.
    func answerOnboarding(_ yes: Bool) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        UserDefaults.standard.set(true, forKey: answeredKey(uid))
        askOnboardingQuestion = false
        if yes { await setOn(true) }
    }

    func setOn(_ on: Bool) async {
        guard SocialFeature.isAvailable, let uid = Auth.auth().currentUser?.uid else { return }
        busy = true
        defer { busy = false }
        do {
            if on {
                let now = ISO8601DateFormatter().string(from: Date())
                _ = try await functions.httpsCallable("recordConsent").call([
                    "recordId": SocialFeature.consentRecordId,
                    "category": "social_activity",
                    "purpose": "Share whether I trained today and my weekly streak with friends I invite, and let the coach mention theirs.",
                    "granted": true,
                    "grantedAt": now,
                    "scope": ["read": true, "write": false, "share": true, "retrieval": false],
                    "policyVersion": SocialFeature.policyVersion,
                ])
                isOn = true
                await loadFriends()
            } else {
                // Server removes your activity and every connection, both ways.
                _ = try await functions.httpsCallable("revokeConsent").call(["recordId": SocialFeature.consentRecordId])
                isOn = false
                friends = []
                invite = nil
            }
            UserDefaults.standard.set(true, forKey: answeredKey(uid))
        } catch {
            note = "Couldn't change that. Try again in a moment."
        }
    }

    func loadFriends() async {
        guard SocialFeature.isAvailable, isOn else { return }
        do {
            let result = try await functions.httpsCallable("getSocialFriendsCallable").call(["today": Self.today()])
            struct Response: Decodable { let friends: [SocialFriend] }
            let json = try JSONSerialization.data(withJSONObject: result.data)
            friends = try JSONDecoder().decode(Response.self, from: json).friends
        } catch {
            note = "Couldn't load friends."
        }
    }

    func makeInvite() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await functions.httpsCallable("createSocialInviteCallable").call([:])
            let data = result.data as? [String: Any]
            if let code = data?["code"] as? String, let link = data?["link"] as? String {
                invite = (code, link)
            }
        } catch {
            note = "Couldn't make an invite."
        }
    }

    func accept(_ raw: String) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await functions.httpsCallable("acceptSocialInviteCallable").call(["code": raw])
            let name = (result.data as? [String: Any])?["firstName"] as? String ?? "your friend"
            note = "You and \(name) are training together."
            pendingCode = nil
            await loadFriends()
        } catch {
            let message = (error as NSError).localizedDescription
            if message.contains("expired") {
                note = "That invite has expired. Ask for a new one."
            } else if message.contains("yours") {
                note = "That's your own invite — send it to a friend."
            } else {
                note = "That code didn't work. Check it and try again."
            }
        }
    }

    func leave(_ friend: SocialFriend) async {
        do {
            _ = try await functions.httpsCallable("leaveSocialConnectionCallable").call(["friendId": friend.friendId])
            friends.removeAll { $0.friendId == friend.friendId }
        } catch {
            note = "Couldn't remove \(friend.firstName)."
        }
    }

    /// myo://join/CODE — only acted on when the prototype is available.
    func handle(url: URL) -> Bool {
        guard SocialFeature.isAvailable, url.scheme == "myo", url.host == "join" else { return false }
        let code = url.lastPathComponent
        guard !code.isEmpty, code != "/" else { return false }
        pendingCode = code
        return true
    }

    func signedOut() {
        loadedFor = nil
        isOn = false
        friends = []
        invite = nil
        askOnboardingQuestion = false
        pendingCode = nil
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

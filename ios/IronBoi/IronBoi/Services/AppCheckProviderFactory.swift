import FirebaseAppCheck
import FirebaseCore
import Foundation

// Phase 3 Task 3.2 — App Check provider factory.
//
// Vends tokens that prove this is a legitimate IronBoi build on a
// legitimate Apple device. The Firebase iOS SDK ships these tokens
// automatically on every callable invocation. The backend rejects any
// call without a valid token (see CALLABLE_OPTS in functions/src/index.ts).
//
// Two providers:
//   - App Attest (Release): hardware-backed attestation. iOS 14+ on
//     real devices only.
//   - Debug provider (Debug): generates a token tied to a debug secret.
//     For simulators + early device testing where App Attest isn't
//     available. The debug token must be added to the Firebase Console
//     under App Check → Debug tokens once the app prints its UUID to
//     the console on first launch.
//
// SET UP STEPS (one-time per developer):
//   1. Run a Debug build on simulator.
//   2. Watch the console for: "App Check debug token: <UUID>".
//   3. Copy that UUID into Firebase Console → Project Settings →
//      App Check → IronBoi (iOS) → ⋯ → Manage debug tokens → Add.
//   4. Now Debug builds can authenticate against staging.

final class IronBoiAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if DEBUG
        // Debug builds (simulator, dev devices): use the debug provider
        // and surface the token on first run so it can be added to
        // Firebase Console.
        return AppCheckDebugProvider(app: app)
        #else
        // Release builds (TestFlight, App Store): use App Attest.
        // Apple guarantees this is available on iOS 14+ — our deployment
        // target is iOS 17.
        return AppAttestProvider(app: app)
        #endif
    }
}

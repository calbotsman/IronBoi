import Foundation

/// One change to the workout in progress, decided by the coach's tool
/// (functions/src/coach/workoutWeightTool.ts `WorkoutAction`). Carried in a
/// reply's `clientActions` (CoachClientAction.weight).
struct CoachWorkoutAction: Equatable {
    enum Kind: String {
        /// Change the weight: `toLb` or `byLb`, in pounds, read with `basis`.
        case setWeight = "set_weight"
        /// They're changing the weight but gave no number: listen for it.
        case askWeight = "ask_weight"
    }
    let kind: Kind
    let exerciseName: String
    var toLb: Double? = nil
    var byLb: Double? = nil
    var basis: WeightRequest.Stated? = nil

    init?(_ raw: [String: Any]) {
        guard let kind = (raw["type"] as? String).flatMap(Kind.init(rawValue:)),
              let name = raw["exerciseName"] as? String, !name.isEmpty else { return nil }
        self.kind = kind
        self.exerciseName = name
        toLb = (raw["toLb"] as? NSNumber)?.doubleValue
        byLb = (raw["byLb"] as? NSNumber)?.doubleValue
        basis = (raw["basis"] as? String).flatMap(WeightRequest.Stated.init(rawValue:))
        if kind == .setWeight, (toLb == nil) == (byLb == nil) { return nil }
    }

    /// The weight change, for WeightLoad.resolve.
    var request: WeightRequest? {
        if let toLb { return WeightRequest(change: .to(toLb), stated: basis) }
        if let byLb { return WeightRequest(change: .by(byLb), stated: basis) }
        return nil
    }
}

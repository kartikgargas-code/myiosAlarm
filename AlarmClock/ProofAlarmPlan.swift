import Foundation
struct ProofAlarmPlan: Equatable {
    let fireDate: Date
    static func twoMinutesAhead(from now: Date) -> ProofAlarmPlan {
        ProofAlarmPlan(fireDate: now.addingTimeInterval(120))
    }
}

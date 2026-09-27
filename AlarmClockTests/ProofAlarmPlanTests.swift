import XCTest
@testable import AlarmClock
final class ProofAlarmPlanTests: XCTestCase {
    func testTwoMinutesAhead() {
        let now = Date(timeIntervalSince1970: 1_000)
        let plan = ProofAlarmPlan.twoMinutesAhead(from: now)
        XCTAssertEqual(plan.fireDate, Date(timeIntervalSince1970: 1_120))
    }
}

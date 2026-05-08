#if canImport(XCTest)
import XCTest
@testable import UboSwift

final class ReconnectPolicyTests: XCTestCase {
    func testFastPhaseReturnsInitialDelay() {
        let policy = ReconnectPolicy.default
        for attempt in 1...8 {
            XCTAssertEqual(
                policy.delaySeconds(forAttempt: attempt),
                0.2,
                accuracy: 0.0001,
                "attempt \(attempt) should be in the fast phase"
            )
        }
    }

    func testExponentialPhaseStartsAtBaseDelay() {
        let policy = ReconnectPolicy.default
        XCTAssertEqual(policy.delaySeconds(forAttempt: 9), 1.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delaySeconds(forAttempt: 10), 2.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delaySeconds(forAttempt: 11), 4.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delaySeconds(forAttempt: 12), 8.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delaySeconds(forAttempt: 13), 16.0, accuracy: 0.0001)
    }

    func testCapsAtMaxDelay() {
        let policy = ReconnectPolicy.default
        XCTAssertEqual(policy.delaySeconds(forAttempt: 14), 30.0, accuracy: 0.0001)
        XCTAssertEqual(policy.delaySeconds(forAttempt: 50), 30.0, accuracy: 0.0001)
    }

    func testNonePolicyAlwaysZero() {
        let policy = ReconnectPolicy.none
        for attempt in 1...10 {
            XCTAssertEqual(policy.delaySeconds(forAttempt: attempt), 0.0)
        }
    }

    func testInvalidAttemptZero() {
        let policy = ReconnectPolicy.default
        XCTAssertEqual(policy.delaySeconds(forAttempt: 0), 0.0)
        XCTAssertEqual(policy.delaySeconds(forAttempt: -1), 0.0)
    }
}
#endif

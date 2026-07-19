import Foundation
import XCTest
@testable import VoiceMixCore

final class QueuedRetryPolicyTests: XCTestCase {

    // MARK: Retry-After parsing (item 1)

    func testParseRetryAfterAcceptsPlainInteger() {
        XCTAssertEqual(QueuedRetryPolicy.parseRetryAfter("30"), 30)
        XCTAssertEqual(QueuedRetryPolicy.parseRetryAfter("0"), 0)
        XCTAssertEqual(QueuedRetryPolicy.parseRetryAfter("120"), 120)
    }

    func testParseRetryAfterTrimsWhitespace() {
        XCTAssertEqual(QueuedRetryPolicy.parseRetryAfter("  45 "), 45)
    }

    func testParseRetryAfterRejectsInvalidValues() {
        XCTAssertNil(QueuedRetryPolicy.parseRetryAfter(nil))
        XCTAssertNil(QueuedRetryPolicy.parseRetryAfter(""))
        XCTAssertNil(QueuedRetryPolicy.parseRetryAfter("abc"))
        XCTAssertNil(QueuedRetryPolicy.parseRetryAfter("12.5"))   // HTTP-date form / float — not integer seconds
        XCTAssertNil(QueuedRetryPolicy.parseRetryAfter("-5"))
        XCTAssertNil(QueuedRetryPolicy.parseRetryAfter("30s"))
    }

    // MARK: Countdown / remaining math (items 2, 4)

    func testDeadlineAddsEtaAndJitter() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = QueuedRetryPolicy.deadline(anchor: anchor, eta: 40, jitter: 1.5)
        XCTAssertEqual(deadline.timeIntervalSinceReferenceDate, 1041.5, accuracy: 0.0001)
    }

    func testRemainingIsDeadlineMinusNow() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = now.addingTimeInterval(12)
        XCTAssertEqual(QueuedRetryPolicy.remaining(deadline: deadline, now: now), 12, accuracy: 0.0001)
    }

    func testRemainingGoesNegativeWhenOverdue() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = now.addingTimeInterval(-3)
        XCTAssertLessThan(QueuedRetryPolicy.remaining(deadline: deadline, now: now), 0)
    }

    func testDisplaySecondsRoundsUpAndClampsAtZero() {
        XCTAssertEqual(QueuedRetryPolicy.displaySeconds(remaining: 3.2), 4)
        XCTAssertEqual(QueuedRetryPolicy.displaySeconds(remaining: 4.0), 4)
        XCTAssertEqual(QueuedRetryPolicy.displaySeconds(remaining: 0), 0)
        XCTAssertEqual(QueuedRetryPolicy.displaySeconds(remaining: -2.5), 0)
    }

    // MARK: 4-minute budget from firstQueuedAt (item 3)

    func testBudgetNotExhaustedWithinFourMinutes() {
        let first = Date()
        let now = first.addingTimeInterval(120)
        XCTAssertFalse(QueuedRetryPolicy.budgetExhausted(firstQueuedAt: first, now: now))
    }

    func testBudgetExhaustedAtFourMinutes() {
        let first = Date()
        let now = first.addingTimeInterval(QueuedRetryPolicy.maxBudgetSeconds)
        XCTAssertTrue(QueuedRetryPolicy.budgetExhausted(firstQueuedAt: first, now: now))
    }

    func testBudgetExhaustedPastFourMinutes() {
        let first = Date()
        let now = first.addingTimeInterval(QueuedRetryPolicy.maxBudgetSeconds + 30)
        XCTAssertTrue(QueuedRetryPolicy.budgetExhausted(firstQueuedAt: first, now: now))
    }

    // MARK: 4-attempt ceiling (item 3)

    func testAttemptsNotExhaustedUpToMax() {
        XCTAssertFalse(QueuedRetryPolicy.attemptsExhausted(1))
        XCTAssertFalse(QueuedRetryPolicy.attemptsExhausted(QueuedRetryPolicy.maxAttempts))
    }

    func testAttemptsExhaustedBeyondMax() {
        XCTAssertTrue(QueuedRetryPolicy.attemptsExhausted(QueuedRetryPolicy.maxAttempts + 1))
    }

    // MARK: Combined give-up decision (items 3, 4)

    func testShouldGiveUpWhenAttemptsExceeded() {
        let first = Date()
        XCTAssertTrue(QueuedRetryPolicy.shouldGiveUp(attempts: 5, firstQueuedAt: first, now: first))
    }

    func testShouldGiveUpWhenBudgetSpentEvenWithAttemptsLeft() {
        let first = Date()
        let now = first.addingTimeInterval(QueuedRetryPolicy.maxBudgetSeconds + 1)
        XCTAssertTrue(QueuedRetryPolicy.shouldGiveUp(attempts: 1, firstQueuedAt: first, now: now))
    }

    func testShouldContinueWithAttemptsAndBudgetRemaining() {
        let first = Date()
        let now = first.addingTimeInterval(60)
        XCTAssertFalse(QueuedRetryPolicy.shouldGiveUp(attempts: 2, firstQueuedAt: first, now: now))
    }
}

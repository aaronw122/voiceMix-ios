import Foundation

/// Pure, UIKit-free logic for the queued auto-retry state machine so it can be
/// unit-tested without the MainActor view model. All wall-clock math is `Date`
/// based off an in-memory anchor (suspended-only scope — no disk persistence).
enum QueuedRetryPolicy {
    /// Max auto-attempts (fresh 503s while queued) before falling back to record.
    static let maxAttempts = 4
    /// Max total queued time, anchored to the in-memory `firstQueuedAt`.
    static let maxBudgetSeconds: TimeInterval = 4 * 60
    /// ETA used when a 503 omits a usable integer `Retry-After`.
    static let fallbackETASeconds = 30
    /// Random slack added to each countdown so retries don't collide in lockstep.
    static let maxJitterSeconds: Double = 2

    /// Parse an integer-seconds `Retry-After` header. Per the backend contract it
    /// is always integer seconds; returns nil for missing/negative/non-integer.
    static func parseRetryAfter(_ value: String?) -> Int? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty,
              let seconds = Int(trimmed), seconds >= 0 else { return nil }
        return seconds
    }

    /// Countdown deadline: anchor + eta + jitter. Resubmit fires at/after this.
    static func deadline(anchor: Date, eta: Int, jitter: Double) -> Date {
        anchor.addingTimeInterval(Double(eta) + jitter)
    }

    /// Seconds remaining until resubmit (may be negative when overdue).
    static func remaining(deadline: Date, now: Date = Date()) -> TimeInterval {
        deadline.timeIntervalSince(now)
    }

    /// Status display value: whole seconds, rounded up, never negative.
    static func displaySeconds(remaining: TimeInterval) -> Int {
        max(0, Int(remaining.rounded(.up)))
    }

    /// Whether the total-wait budget is spent (>= 4 min since first queued).
    static func budgetExhausted(firstQueuedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(firstQueuedAt) >= maxBudgetSeconds
    }

    /// Whether the auto-attempt ceiling is passed (attempts counts fresh 503s).
    static func attemptsExhausted(_ attempts: Int) -> Bool {
        attempts > maxAttempts
    }

    /// Combined give-up test used on every entry and every resume.
    static func shouldGiveUp(attempts: Int, firstQueuedAt: Date, now: Date = Date()) -> Bool {
        attemptsExhausted(attempts) || budgetExhausted(firstQueuedAt: firstQueuedAt, now: now)
    }
}

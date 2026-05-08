import Foundation

/// Backoff schedule used by long-lived subscriptions when the underlying
/// stream errors out. Mirrors the schedule the Python GUI client uses
/// (`ubo_app/gui/ubo_gui_client/client.py`):
///
/// - The first `initialFastAttempts` retries are spaced `initialDelay` apart
///   so transient drops feel instant.
/// - Subsequent retries grow exponentially from `baseDelay`, capped at
///   `maxDelay`.
/// - The loop gives up after `maxRetries`.
public struct ReconnectPolicy: Sendable, Equatable {
    public let initialDelaySeconds: Double
    public let initialFastAttempts: Int
    public let baseDelaySeconds: Double
    public let maxDelaySeconds: Double
    public let maxRetries: Int

    public init(
        initialDelaySeconds: Double = 0.2,
        initialFastAttempts: Int = 8,
        baseDelaySeconds: Double = 1.0,
        maxDelaySeconds: Double = 30.0,
        maxRetries: Int = 50
    ) {
        self.initialDelaySeconds = initialDelaySeconds
        self.initialFastAttempts = initialFastAttempts
        self.baseDelaySeconds = baseDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.maxRetries = maxRetries
    }

    public static let `default` = ReconnectPolicy()

    /// Disable retries entirely. The first error finishes the stream.
    public static let none = ReconnectPolicy(
        initialDelaySeconds: 0,
        initialFastAttempts: 0,
        baseDelaySeconds: 0,
        maxDelaySeconds: 0,
        maxRetries: 0
    )

    /// Delay before retry `attempt` (1-indexed). Returns 0 for invalid input.
    public func delaySeconds(forAttempt attempt: Int) -> Double {
        guard attempt >= 1 else { return 0 }
        if attempt <= initialFastAttempts {
            return initialDelaySeconds
        }
        let normalAttempt = attempt - initialFastAttempts
        let exponent = max(0, normalAttempt - 1)
        let computed = baseDelaySeconds * pow(2.0, Double(exponent))
        return min(computed, maxDelaySeconds)
    }
}

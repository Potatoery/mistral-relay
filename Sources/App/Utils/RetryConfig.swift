import NIOCore
import Foundation
import Dispatch

/// Retry configuration for rate-limited requests
///
/// Mirrors the retry policy the official Mistral Python SDK applies to every call made through
/// `mistralai.client.Mistral` (see `mistralai/client/utils/retries.py` and
/// `mistral-vibe`'s `MistralBackend._build_retry_config()`), so this relay backs off the same way
/// a client going straight through that SDK would - same retryable status codes, same backoff
/// curve, same all-time-budget/no-attempt-cap bound.
public struct RetryConfig: Sendable {
    /// Maximum number of retry attempts (nil = unbounded, bounded only by `maxElapsedTime` -
    /// matches the SDK, which never caps attempt count on its own)
    public let maxAttempts: Int?

    /// Initial delay between retries (SDK: `BackoffStrategy.initial_interval` = 500ms)
    public let initialDelay: TimeAmount

    /// Maximum delay between retries (SDK: `BackoffStrategy.max_interval` = 30s)
    public let maxDelay: TimeAmount

    /// Multiplier for exponential backoff (SDK: `BackoffStrategy.exponent` = 1.5)
    public let backoffFactor: Double

    /// Total time budget for all retry attempts (SDK: `BackoffStrategy.max_elapsed_time`,
    /// `DEFAULT_API_RETRY_MAX_ELAPSED_TIME` = 300s in mistral-vibe)
    public let maxElapsedTime: TimeAmount?

    /// Retryable HTTP status codes - the exact set the generated SDK passes as
    /// `retry_config=(retries, ["429", "500", "502", "503", "504"])` for chat completions
    public static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    public init(
        maxAttempts: Int? = nil,
        initialDelay: TimeAmount = .milliseconds(500),
        maxDelay: TimeAmount = .seconds(30),
        backoffFactor: Double = 1.5,
        maxElapsedTime: TimeAmount? = .seconds(300)
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffFactor = backoffFactor
        self.maxElapsedTime = maxElapsedTime
    }

    /// Compute next delay using exponential backoff
    ///
    /// Matches the SDK's `_get_sleep_interval`: a server `Retry-After` is honored exactly (not
    /// capped by `maxDelay` - the SDK trusts the server's own directive), otherwise
    /// `initialDelay * backoffFactor^attempt` plus up to one second of jitter, capped at `maxDelay`.
    /// - Parameters:
    ///   - attempt: Current attempt number (0-based)
    ///   - retryAfter: Optional Retry-After header value
    /// - Returns: Delay before next retry
    public func nextDelay(attempt: Int, retryAfter: TimeAmount?) -> TimeAmount {
        if let retryAfter = retryAfter, retryAfter.nanoseconds > 0 {
            return retryAfter
        }

        let initialSeconds = Double(initialDelay.nanoseconds) / 1_000_000_000
        let maxSeconds = Double(maxDelay.nanoseconds) / 1_000_000_000
        let sleepSeconds = initialSeconds * pow(backoffFactor, Double(attempt)) + Double.random(in: 0..<1)

        return .nanoseconds(Int64(min(sleepSeconds, maxSeconds) * 1_000_000_000))
    }

    /// Whether the retry budget is used up: elapsed time past `maxElapsedTime` (SDK: `now - start
    /// > max_elapsed_time`), or - a relay-only safety net the SDK itself has no equivalent for -
    /// `attempt` reaching `maxAttempts`.
    ///
    /// Mirrors the SDK's behavior on exhaustion: the caller should hand back whatever response or
    /// error it already has rather than raise a synthetic "gave up" error of its own.
    public func isExhausted(elapsedSince startTime: DispatchTime, attempt: Int) -> Bool {
        if let maxElapsed = maxElapsedTime {
            let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
            if TimeAmount.nanoseconds(Int64(elapsed)) > maxElapsed {
                return true
            }
        }
        if let maxAttempts = maxAttempts, attempt >= maxAttempts {
            return true
        }
        return false
    }

    /// Parse a `Retry-After` header value per RFC 9110: delta-seconds (matches the SDK's
    /// `float()` parse, so fractional values like `"1.5"` are honored) or an HTTP-date.
    public static func parseRetryAfter(_ value: String) -> TimeAmount? {
        if let seconds = Double(value) {
            return .nanoseconds(Int64(seconds * 1_000_000_000))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if let date = formatter.date(from: value) {
            let seconds = date.timeIntervalSinceNow
            if seconds > 0 {
                return .nanoseconds(Int64(seconds * 1_000_000_000))
            }
        }

        return nil
    }
}

/// Information about a rate limit event
public struct RateLimitInfo {
    public let statusCode: Int
    public let retryAfter: TimeAmount?
    public let attempt: Int
    
    public init(statusCode: Int, retryAfter: TimeAmount?, attempt: Int) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.attempt = attempt
    }
}

/// Callback for retry events
public typealias RetryCallback = (RateLimitInfo) async -> Void

import Vapor
import AsyncHTTPClient
import NIOCore
import Foundation
import Dispatch

/// Handles streaming requests with retry and keep-alive support
/// 
/// When a rate limit (429) or other retryable error occurs, this handler:
/// 1. Sends keep-alive comments to the client during the retry delay
/// 2. Retries the request with exponential backoff
/// 3. Forwards the successful response stream to the client
///
/// SSE keep-alive format: ": keep-alive\n\n"
public final class StreamingRetryHandler: Sendable {
    private let httpClient: HTTPClient
    private let retryConfig: RetryConfig
    private let logger: Logger

    public init(
        httpClient: HTTPClient,
        retryConfig: RetryConfig = RetryConfig(),
        logger: Logger
    ) {
        self.httpClient = httpClient
        self.retryConfig = retryConfig
        self.logger = logger
    }
    
    /// Execute the first attempt of a request, before any HTTP response has been sent to the client.
    ///
    /// This lets the caller forward the real upstream status code and headers whenever no retry
    /// is needed (the common case), instead of always answering with a placeholder status. Only
    /// once a retry is actually required do we fall back to a long-lived `.ok` stream that keeps
    /// the connection alive with SSE comments during backoff — see `continueStreaming`.
    ///
    /// - Returns: `.complete` with the upstream response ready to forward as-is, or `.retrying`
    ///   with the state needed to resume the retry loop from inside a stream body.
    public func executeInitialAttempt(
        _ request: HTTPClientRequest,
        onRateLimit: RetryCallback? = nil
    ) async throws -> InitialAttemptOutcome {
        let startTime = DispatchTime.now()

        do {
            let response = try await httpClient.execute(request, timeout: .seconds(120))

            guard isRetryableStatus(Int(response.status.code)) else {
                return .complete(response)
            }

            // Read and close the response body to release the connection
            _ = try? await response.body.collect(upTo: 1024 * 1024)

            if retryConfig.isExhausted(elapsedSince: startTime, attempt: 0) {
                // Out of retry budget - hand back this last (still-erroring) response as-is,
                // the same way the SDK returns the final response instead of raising once
                // max_elapsed_time is exceeded.
                logger.warning("Retry budget exhausted, forwarding last response as-is")
                return .complete(response)
            }

            let retryAfter = response.headers.first(name: "Retry-After").flatMap(RetryConfig.parseRetryAfter)
            let delay = retryConfig.nextDelay(attempt: 0, retryAfter: retryAfter)

            logger.warning("Rate limited (attempt: 0), retrying after \(delay)...")

            if let onRateLimit = onRateLimit {
                await onRateLimit(RateLimitInfo(statusCode: Int(response.status.code), retryAfter: retryAfter, attempt: 0))
            }

            return .retrying(PendingRetry(request: request, startTime: startTime, attempt: 1, delay: delay))

        } catch let error as HTTPClientError {
            if isRetryableError(error), !retryConfig.isExhausted(elapsedSince: startTime, attempt: 0) {
                let delay = retryConfig.nextDelay(attempt: 0, retryAfter: nil)
                logger.warning("Network error, retrying after \(delay)...: \(error)")

                return .retrying(PendingRetry(request: request, startTime: startTime, attempt: 1, delay: delay))
            }
            throw error
        }
    }

    /// Resume the retry loop started by `executeInitialAttempt`, sending keep-alive comments
    /// during each backoff delay and finally streaming the successful response to the client.
    public func continueStreaming(
        _ pending: PendingRetry,
        writer: BodyStreamWriter,
        onRateLimit: RetryCallback? = nil
    ) async throws -> HTTPResponseStatus {
        var attempt = pending.attempt

        // The delay for the attempt that triggered the retry hasn't been observed by the client
        // yet (no response existed at that point), so send its keep-alives now before retrying.
        try await sendKeepAliveDuringDelay(pending.delay, writer: writer)

        while true {
            do {
                let response = try await httpClient.execute(pending.request, timeout: .seconds(120))

                guard isRetryableStatus(Int(response.status.code)) else {
                    let finalStatus = HTTPResponseStatus(statusCode: Int(response.status.code))
                    await streamResponse(response, writer: writer)
                    return finalStatus
                }

                _ = try? await response.body.collect(upTo: 1024 * 1024)

                if retryConfig.isExhausted(elapsedSince: pending.startTime, attempt: attempt) {
                    // Out of retry budget - stream this last (still-erroring) response as-is,
                    // the same way the SDK returns the final response instead of raising.
                    logger.warning("Retry budget exhausted, forwarding last response as-is")
                    let finalStatus = HTTPResponseStatus(statusCode: Int(response.status.code))
                    await streamResponse(response, writer: writer)
                    return finalStatus
                }

                let retryAfter = response.headers.first(name: "Retry-After").flatMap(RetryConfig.parseRetryAfter)
                let delay = retryConfig.nextDelay(attempt: attempt, retryAfter: retryAfter)

                logger.warning("Rate limited (attempt: \(attempt)), retrying after \(delay)...")

                if let onRateLimit = onRateLimit {
                    await onRateLimit(RateLimitInfo(statusCode: Int(response.status.code), retryAfter: retryAfter, attempt: attempt))
                }

                try await sendKeepAliveDuringDelay(delay, writer: writer)
                attempt += 1

            } catch let error as HTTPClientError {
                if isRetryableError(error), !retryConfig.isExhausted(elapsedSince: pending.startTime, attempt: attempt) {
                    let delay = retryConfig.nextDelay(attempt: attempt, retryAfter: nil)
                    logger.warning("Network error, retrying after \(delay)...: \(error)")

                    try await sendKeepAliveDuringDelay(delay, writer: writer)
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    /// Stream the response body to the client
    private func streamResponse(_ response: HTTPClientResponse, writer: BodyStreamWriter) async {
        do {
            for try await chunk in response.body {
                _ = writer.write(.buffer(chunk))
            }
            _ = writer.write(.end)
        } catch {
            _ = writer.write(.error(error))
        }
    }
    
    /// Send keep-alive comments during retry delay
    /// 
    /// SSE format: ": keep-alive\n\n"
    /// These are comments in SSE and are ignored by clients
    private func sendKeepAliveDuringDelay(_ delay: TimeAmount, writer: BodyStreamWriter) async throws {
        let keepAliveInterval = TimeAmount.seconds(2)
        let totalNanoseconds = delay.nanoseconds
        
        // Send initial keep-alive immediately
        try await sendKeepAlive(writer: writer)
        
        // Calculate how many more keep-alives to send
        var remaining = totalNanoseconds
        
        while remaining > keepAliveInterval.nanoseconds {
            try await Task.sleep(nanoseconds: UInt64(keepAliveInterval.nanoseconds))
            remaining -= keepAliveInterval.nanoseconds
            try await sendKeepAlive(writer: writer)
        }
        
        // Sleep for the remaining time
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining))
        }
    }
    
    /// Send a single keep-alive comment
    private func sendKeepAlive(writer: BodyStreamWriter) async throws {
        // SSE keep-alive comment format
        // Comments start with ":" and are ignored by SSE parsers
        let keepAliveData = ": keep-alive\n\n"
        let buffer = ByteBuffer(string: keepAliveData)
        _ = writer.write(.buffer(buffer))
        
        logger.debug("Sent keep-alive to client")
    }
    
    /// Check if status code is retryable
    private func isRetryableStatus(_ statusCode: Int) -> Bool {
        return RetryConfig.retryableStatusCodes.contains(statusCode)
    }
    
    /// Check if HTTPClientError is retryable (network/timeout errors)
    private func isRetryableError(_ error: HTTPClientError) -> Bool {
        switch error {
        case .connectTimeout, .readTimeout, .writeTimeout, .remoteConnectionClosed:
            return true
        default:
            return false
        }
    }
}

/// Outcome of the first attempt made by `executeInitialAttempt`
public enum InitialAttemptOutcome: Sendable {
    /// No retry was needed - forward this response's real status/headers/body to the client.
    case complete(HTTPClientResponse)
    /// The first attempt was retryable - resume via `continueStreaming` from inside a stream body.
    case retrying(PendingRetry)
}

/// State needed to resume a retry sequence that was started before any response was sent to the client
public struct PendingRetry: Sendable {
    let request: HTTPClientRequest
    let startTime: DispatchTime
    let attempt: Int
    let delay: TimeAmount
}

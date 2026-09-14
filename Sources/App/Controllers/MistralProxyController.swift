import Vapor
import AsyncHTTPClient
import NIOCore
import Dispatch

struct MistralProxyController: RouteCollection {

    // HTTP client for forwarding requests
    let httpClient: HTTPClient
    
    // Shared retry handler for streaming requests
    let streamingRetryHandler: StreamingRetryHandler

    init(httpClient: HTTPClient = HTTPClient()) {
        self.httpClient = httpClient
        self.streamingRetryHandler = StreamingRetryHandler(
            httpClient: httpClient,
            logger: Logger(label: "com.mistral.relay")
        )
    }

    func boot(routes: RoutesBuilder) throws {
        // Health check endpoint
        routes.get("health", use: healthCheck)

        // API routes
        let mistralRoutes = routes.grouped("api", "v1", "chat")
        mistralRoutes.on(.POST, .constant("completions"), body: .stream, use: proxyToMistral)
        
        // Models endpoint
        let modelsRoutes = routes.grouped("api", "v1", "models")
        modelsRoutes.get(use: getModels)
    }

    /// Health check endpoint
    func healthCheck(req: Request) -> Response {
        return Response(status: .ok, body: .init(string: "OK"))
    }

    /// Proxy request to Mistral API with retry and keep-alive support
    func proxyToMistral(req: Request) async throws -> Response {
        let targetURL = AppConfig.Mistral.baseURL + AppConfig.Mistral.chatCompletionsPath

        // 1. Collect and filter the request body
        let bodyBuffer = try await req.body.collect(upTo: 1024 * 1024)
        let filteredBodyByteBuffer: ByteBuffer

        if let jsonData = try? JSONSerialization.jsonObject(with: Data(buffer: bodyBuffer)) as? [String: Any] {
            let filteredRequestBody = MistralParameters.filterRequestBody(jsonData, logger: req.logger)
            if let filteredData = try? JSONSerialization.data(withJSONObject: filteredRequestBody) {
                filteredBodyByteBuffer = ByteBuffer(bytes: filteredData)
            } else {
                filteredBodyByteBuffer = bodyBuffer
            }
        } else {
            filteredBodyByteBuffer = bodyBuffer
        }

        // 2. Safely reconstruct headers (using replaceOrAdd and first(named:) to prevent duplication/splitting)
        var headers = HTTPHeaders()
        
        // Copy headers based on Allowed / Blocked list
        let allowedHeaders = AppConfig.Mistral.allowedHeaders.map { $0.lowercased() }
        let blockedHeaders = AppConfig.Mistral.blockedHeaders.map { $0.lowercased() }

        for allowedName in allowedHeaders {
            if blockedHeaders.contains(allowedName) { continue }
            
            // req.headers[allowedName] returns an array of [String].
            // Join the split segments back into a single string.
            let values = req.headers[allowedName]
            if !values.isEmpty {
                let combinedValue = values.joined()
                headers.replaceOrAdd(name: allowedName, value: combinedValue)
            }
        }

        // 3. Create HTTPClientRequest
        var httpRequest = HTTPClientRequest(url: targetURL)
        httpRequest.method = .POST
        httpRequest.headers = headers
        httpRequest.body = .bytes(filteredBodyByteBuffer)
        
        // 4. Run the first attempt inline so success/non-retryable responses can forward the
        // real upstream status and headers. Only fall back to an always-.ok keep-alive stream
        // (see StreamingRetryHandler.continueStreaming) once a retry is actually required -
        // that path can't know the eventual status ahead of time.
        let retryHandler = streamingRetryHandler
        let outcome = try await retryHandler.executeInitialAttempt(httpRequest)

        switch outcome {
        case .complete(let upstreamResponse):
            let status = HTTPResponseStatus(statusCode: Int(upstreamResponse.status.code))
            var responseHeaders = HTTPHeaders()
            for header in upstreamResponse.headers {
                responseHeaders.add(name: header.name, value: header.value)
            }

            let body = Response.Body(stream: { writer in
                Task {
                    do {
                        for try await chunk in upstreamResponse.body {
                            _ = writer.write(.buffer(chunk))
                        }
                        _ = writer.write(.end)
                    } catch {
                        req.logger.error("Streaming failed: \(error)")
                        _ = writer.write(.error(error))
                    }
                }
            })

            return Response(status: status, headers: responseHeaders, body: body)

        case .retrying(let pending):
            // We already know the first attempt needs a retry, so there's no status to report
            // yet - answer with .ok now and keep the connection alive with SSE comments while
            // backing off, the same way a genuinely long-running stream would.
            let body = Response.Body(stream: { writer in
                Task {
                    do {
                        let finalStatus = try await retryHandler.continueStreaming(pending, writer: writer)
                        req.logger.debug("Streaming completed with status \(finalStatus)")
                    } catch {
                        req.logger.error("All retries failed: \(error)")
                        _ = writer.write(.error(error))
                    }
                }
            })

            return Response(status: .ok, headers: [:], body: body)
        }
    }

    /// Get available models from Mistral API
    func getModels(req: Request) async throws -> Response {
        let targetURL = AppConfig.Mistral.baseURL + AppConfig.Mistral.modelsPath
        
        // Create and send HTTPClientRequest
        var httpRequest = HTTPClientRequest(url: targetURL)
        httpRequest.method = .GET
        
        // Forward relevant headers
        var headers = HTTPHeaders()
        let allowedHeaders = AppConfig.Mistral.allowedHeaders.map { $0.lowercased() }
        let blockedHeaders = AppConfig.Mistral.blockedHeaders.map { $0.lowercased() }

        for allowedName in allowedHeaders {
            if blockedHeaders.contains(allowedName) { continue }
            let values = req.headers[allowedName]
            if !values.isEmpty {
                let combinedValue = values.joined()
                headers.replaceOrAdd(name: allowedName, value: combinedValue)
            }
        }
        
        httpRequest.headers = headers
        
        // For non-streaming requests, use simple retry without keep-alive
        // This is simpler since we don't need to maintain a stream during retry
        let response = try await executeWithRetry(httpRequest)
        
        // Collect the entire response body
        var responseBody = ByteBuffer()
        for try await chunk in response.body {
            responseBody.writeImmutableBuffer(chunk)
        }

        // Copy response headers
        var responseHeaders = HTTPHeaders()
        for header in response.headers {
            responseHeaders.add(name: header.name, value: header.value)
        }

        return Response(status: response.status, headers: responseHeaders, body: .init(buffer: responseBody))
    }
    
    /// Execute a non-streaming request with simple retry (no keep-alive needed)
    private func executeWithRetry(_ request: HTTPClientRequest) async throws -> HTTPClientResponse {
        let retryConfig = RetryConfig()
        let startTime = DispatchTime.now()
        var attempt = 0

        while true {
            do {
                let response = try await httpClient.execute(request, timeout: .seconds(120))

                guard isRetryableStatus(Int(response.status.code)) else {
                    return response
                }

                // Retryable error - read and close response
                _ = try? await response.body.collect(upTo: 1024 * 1024)

                if retryConfig.isExhausted(elapsedSince: startTime, attempt: attempt) {
                    // Out of retry budget - hand back this last (still-erroring) response as-is,
                    // the same way the official SDK returns the final response instead of raising.
                    return response
                }

                let retryAfter = response.headers.first(name: "Retry-After").flatMap(RetryConfig.parseRetryAfter)
                let delay = retryConfig.nextDelay(attempt: attempt, retryAfter: retryAfter)

                try await Task.sleep(nanoseconds: UInt64(delay.nanoseconds))
                attempt += 1

            } catch let error as HTTPClientError {
                if isRetryableNetworkError(error), !retryConfig.isExhausted(elapsedSince: startTime, attempt: attempt) {
                    let delay = retryConfig.nextDelay(attempt: attempt, retryAfter: nil)
                    try await Task.sleep(nanoseconds: UInt64(delay.nanoseconds))
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    private func isRetryableStatus(_ statusCode: Int) -> Bool {
        return RetryConfig.retryableStatusCodes.contains(statusCode)
    }

    private func isRetryableNetworkError(_ error: HTTPClientError) -> Bool {
        switch error {
        case .connectTimeout, .readTimeout, .writeTimeout, .remoteConnectionClosed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Extension for Application Registration
extension Application {
    func addMistralProxyRoutes() {
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init()
        )
        let controller = MistralProxyController(httpClient: httpClient)
        try! routes.register(collection: controller)

        // Store HTTP client for cleanup
        self.httpClient = httpClient

        // Register lifecycle handler to shut down HTTPClient on application shutdown
        self.lifecycle.use(HTTPClientLifecycleHandler())
    }

    private struct HTTPClientLifecycleHandler: LifecycleHandler {
        func shutdown(_ app: Application) {
            if let httpClient = app.httpClient {
                do {
                    try httpClient.syncShutdown()
                    app.logger.info("HTTP client shutdown gracefully")
                } catch {
                    app.logger.error("Error shutting down HTTP client: \(error)")
                }
            }
        }
    }

    private struct HTTPClientKey: StorageKey {
        typealias Value = HTTPClient
    }

    var httpClient: HTTPClient? {
        get { self.storage[HTTPClientKey.self] }
        set { self.storage[HTTPClientKey.self] = newValue }
    }
}

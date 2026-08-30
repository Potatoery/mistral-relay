import Vapor
import AsyncHTTPClient
import NIOCore

struct MistralProxyController: RouteCollection {

    // HTTP client for forwarding requests
    let httpClient: HTTPClient

    init(httpClient: HTTPClient = HTTPClient()) {
        self.httpClient = httpClient
    }

    func boot(routes: RoutesBuilder) throws {
        // Health check endpoint
        routes.get("health", use: healthCheck)

        // API routes
        let mistralRoutes = routes.grouped("api", "v1")
        mistralRoutes.post("completions", use: proxyToMistral)
    }

    /// Health check endpoint
    func healthCheck(req: Request) -> Response {
        return Response(status: .ok, body: .init(string: "OK"))
    }

    /// Proxy request to Mistral API
    func proxyToMistral(req: Request) async throws -> Response {
        // Build the target URL
        let targetURL = AppConfig.Mistral.baseURL + AppConfig.Mistral.chatCompletionsPath

        // Get the request body
        let bodyBuffer = try await req.body.collect(upTo: 1024 * 1024) // 1MB limit

        // Parse JSON body to filter parameters
        let bodyString = String(buffer: bodyBuffer)

        // Try to parse and filter the request body parameters
        let filteredBodyByteBuffer: ByteBuffer
        if let jsonData = bodyString.data(using: .utf8),
           var requestBody = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

            // Filter out unsupported parameters
            requestBody = MistralParameters.filterRequestBody(requestBody)

            // Re-encode the filtered body
            if let filteredData = try? JSONSerialization.data(withJSONObject: requestBody) {
                filteredBodyByteBuffer = ByteBuffer(bytes: filteredData)
            } else {
                filteredBodyByteBuffer = bodyBuffer
            }
        } else {
            // If not valid JSON, forward as-is
            filteredBodyByteBuffer = bodyBuffer
        }

        // Build filtered headers for Mistral
        var headers = HTTPHeaders()

        let allowedHeaders = AppConfig.Mistral.allowedHeaders
        let blockedHeaders = AppConfig.Mistral.blockedHeaders

        for (name, value) in req.headers {
            let lowercasedName = name.lowercased()

            // Skip blocked headers
            if blockedHeaders.contains(lowercasedName) {
                continue
            }

            // Only forward allowed headers
            if allowedHeaders.contains(lowercasedName) {
                headers.add(name: name, value: value)
            }
        }

        // Ensure we have content-type for JSON
        if headers["content-type"].isEmpty && headers["Content-Type"].isEmpty {
            headers.add(name: "Content-Type", value: "application/json")
        }

        // Create HTTPClientRequest
        var httpRequest = HTTPClientRequest(url: targetURL)
        httpRequest.method = .POST
        httpRequest.headers = headers
        httpRequest.body = .bytes(filteredBodyByteBuffer)

        // Execute the request with timeout
        let httpResponse = try await httpClient.execute(httpRequest, timeout: .seconds(120))

        // Create Vapor response from Mistral response
        let status = HTTPResponseStatus(statusCode: Int(httpResponse.status.code))
        let vaporResponse = Response(status: status, headers: httpResponse.headers)

        // Collect response body
        let responseBodyBuffer = try await httpResponse.body.collect(upTo: 1024 * 1024)
        vaporResponse.body = Response.Body(buffer: responseBodyBuffer)

        return vaporResponse
    }
}

// Extension for easy registration
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

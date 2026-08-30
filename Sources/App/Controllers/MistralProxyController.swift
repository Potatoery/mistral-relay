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
        let mistralRoutes = routes.grouped("api", "v1", "chat")
        mistralRoutes.on(.POST, .constant("completions"), body: .stream, use: proxyToMistral)
    }

    /// Health check endpoint
    func healthCheck(req: Request) -> Response {
        return Response(status: .ok, body: .init(string: "OK"))
    }

    /// Proxy request to Mistral API
    /// Proxy request to Mistral API
    func proxyToMistral(req: Request) async throws -> Response {
        let targetURL = AppConfig.Mistral.baseURL + AppConfig.Mistral.chatCompletionsPath

        // 1. Request Body 수집 및 필터링
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

        // 2. 안전한 헤더 재구성 (replaceOrAdd 및 first(named:) 사용으로 중복/분할 방지)
        var headers = HTTPHeaders()
        
        // Allowed / Blocked 목록 기반 헤더 복사
        let allowedHeaders = AppConfig.Mistral.allowedHeaders.map { $0.lowercased() }
        let blockedHeaders = AppConfig.Mistral.blockedHeaders.map { $0.lowercased() }

        for allowedName in allowedHeaders {
            if blockedHeaders.contains(allowedName) { continue }
            
            // req.headers[allowedName]은 [String] 배열을 반환합니다.
            // 쪼개져 들어온 문자들을 하나의 문자열로 다시 이어붙입니다.
            let values = req.headers[allowedName]
            if !values.isEmpty {
                let combinedValue = values.joined()
                headers.replaceOrAdd(name: allowedName, value: combinedValue)
            }
        }

        // 3. HTTPClientRequest 생성 및 전송
        var httpRequest = HTTPClientRequest(url: targetURL)
        httpRequest.method = .POST
        httpRequest.headers = headers
        httpRequest.body = .bytes(filteredBodyByteBuffer)
        

        let httpResponse = try await httpClient.execute(httpRequest, timeout: .seconds(120))
        let status = HTTPResponseStatus(statusCode: Int(httpResponse.status.code))

        // 4. Vapor Response 헤더 복사
        var responseHeaders = HTTPHeaders()
        for header in httpResponse.headers {
            responseHeaders.add(name: header.name, value: header.value)
        }

        // 5. 스트리밍 응답 전달
        let body = Response.Body(stream: { writer in
            Task {
                do {
                    for try await chunk in httpResponse.body {
                        _ = writer.write(.buffer(chunk))
                    }
                    _ = writer.write(.end)
                } catch {
                    _ = writer.write(.error(error))
                }
            }
        })

        return Response(status: status, headers: responseHeaders, body: body)
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

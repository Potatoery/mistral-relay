@testable import App
import XCTest
import Vapor

final class HeaderFilterTests: XCTestCase {
    
    func testHeaderFilterMiddlewareFiltersUnsupportedHeaders() async throws {
        // Create a test application
        let app = try await Application.make(.testing)
        
        do {
            // Configure the app
            try await configure(app)
            
            // Create a test request with mixed headers
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Authorization", value: "Bearer test-key")
            headers.add(name: "Custom-Header", value: "should-be-filtered")
            headers.add(name: "X-Another-Custom", value: "also-filtered")
            headers.add(name: "Accept", value: "application/json")
            
            let request = Request(
                application: app,
                method: .POST,
                url: "/api/v1/chat/completions",
                headers: headers,
                on: app.eventLoopGroup.next()
            )
            
            // Create the middleware
            let middleware = HeaderFilterMiddleware()
            
            // Create a mock responder that captures the modified request
            let capturedRequest = ThreadSafeRequestContainer()
            let mockResponder = MockResponder { req in
                capturedRequest.set(req)
                return Response(status: .ok)
            }
            
            // Run the middleware
            _ = try await middleware.respond(to: request, chainingTo: mockResponder)
            
            // Verify the captured request has filtered headers
            guard let resultRequest = capturedRequest.get() else {
                XCTFail("Request was not captured")
                try await app.asyncShutdown()
                return
            }
            
            let resultHeaders = resultRequest.headers
            
            // Should have allowed headers
            XCTAssertFalse(resultHeaders["Content-Type"].isEmpty)
            XCTAssertFalse(resultHeaders["Authorization"].isEmpty)
            XCTAssertFalse(resultHeaders["Accept"].isEmpty)
            
            // Should NOT have unsupported headers
            XCTAssertTrue(resultHeaders["Custom-Header"].isEmpty)
            XCTAssertTrue(resultHeaders["X-Another-Custom"].isEmpty)
            
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
    
    func testHeaderFilterMiddlewareBlocksHopByHopHeaders() async throws {
        let app = try await Application.make(.testing)
        
        do {
            try await configure(app)
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Authorization", value: "Bearer test-key")
            headers.add(name: "Host", value: "localhost")
            headers.add(name: "Content-Length", value: "100")
            headers.add(name: "Connection", value: "keep-alive")
            
            let request = Request(
                application: app,
                method: .POST,
                url: "/api/v1/chat/completions",
                headers: headers,
                on: app.eventLoopGroup.next()
            )
            
            let middleware = HeaderFilterMiddleware()
            let capturedRequest = ThreadSafeRequestContainer()
            let mockResponder = MockResponder { req in
                capturedRequest.set(req)
                return Response(status: .ok)
            }
            
            _ = try await middleware.respond(to: request, chainingTo: mockResponder)
            
            guard let resultRequest = capturedRequest.get() else {
                XCTFail("Request was not captured")
                try await app.asyncShutdown()
                return
            }
            
            let resultHeaders = resultRequest.headers
            
            // Should have allowed headers
            XCTAssertFalse(resultHeaders["Content-Type"].isEmpty)
            XCTAssertFalse(resultHeaders["Authorization"].isEmpty)
            
            // Should NOT have hop-by-hop headers
            XCTAssertTrue(resultHeaders["Host"].isEmpty)
            XCTAssertTrue(resultHeaders["Content-Length"].isEmpty)
            // Connection is in allowed list, so it should be present
            XCTAssertFalse(resultHeaders["Connection"].isEmpty)
            
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
    
    func testHeaderFilterMiddlewareAddsContentTypeIfMissing() async throws {
        let app = try await Application.make(.testing)
        
        do {
            try await configure(app)
            
            var headers = HTTPHeaders()
            headers.add(name: "Authorization", value: "Bearer test-key")
            
            let request = Request(
                application: app,
                method: .POST,
                url: "/api/v1/chat/completions",
                headers: headers,
                on: app.eventLoopGroup.next()
            )
            
            let middleware = HeaderFilterMiddleware()
            let capturedRequest = ThreadSafeRequestContainer()
            let mockResponder = MockResponder { req in
                capturedRequest.set(req)
                return Response(status: .ok)
            }
            
            _ = try await middleware.respond(to: request, chainingTo: mockResponder)
            
            guard let resultRequest = capturedRequest.get() else {
                XCTFail("Request was not captured")
                try await app.asyncShutdown()
                return
            }
            
            let resultHeaders = resultRequest.headers
            
            // Should have added Content-Type
            XCTAssertFalse(resultHeaders["Content-Type"].isEmpty)
            XCTAssertEqual(resultHeaders["Content-Type"].first, "application/json")
            
            try await app.asyncShutdown()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
    }
}

// Thread-safe wrapper to capture Request under concurrency
final class ThreadSafeRequestContainer: @unchecked Sendable {
    private let lock = NSLock()
    private var request: Request?
    
    func set(_ req: Request) {
        lock.lock()
        defer { lock.unlock() }
        self.request = req
    }
    
    func get() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return self.request
    }
}

// Mock responder for testing
struct MockResponder: AsyncResponder {
    let handler: @Sendable (Request) -> Response
    
    init(handler: @escaping @Sendable (Request) -> Response) {
        self.handler = handler
    }
    
    func respond(to request: Request) async throws -> Response {
        handler(request)
    }
}

import Vapor

struct HeaderFilterMiddleware: AsyncMiddleware {
    
    private let allowedHeaders: Set<String>
    private let blockedHeaders: Set<String>
    
    init(allowedHeaders: Set<String> = AppConfig.Mistral.allowedHeaders,
         blockedHeaders: Set<String> = AppConfig.Mistral.blockedHeaders) {
        self.allowedHeaders = allowedHeaders
        self.blockedHeaders = blockedHeaders
    }
    
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Build filtered headers using Dictionary first, then convert to HTTPHeaders
        var headerDict: [String: [String]] = [:]
        
        for (name, values) in request.headers {
            let lowercasedName = name.lowercased()
            
            // Skip blocked headers (hop-by-hop)
            if blockedHeaders.contains(lowercasedName) {
                continue
            }
            
            // Only include headers that are in the allowed set
            if allowedHeaders.contains(lowercasedName) {
                headerDict[name] = values.map { String($0) }
            }
        }
        
        // Add required headers for Mistral API if not present
        if headerDict["Content-Type"] == nil && headerDict["content-type"] == nil {
            headerDict["Content-Type"] = ["application/json"]
        }
        
        // Convert dictionary to HTTPHeaders
        var filteredHeaders = HTTPHeaders()
        for (name, values) in headerDict {
            for value in values {
                filteredHeaders.add(name: name, value: value)
            }
        }
        
        // Update request headers
        request.headers = filteredHeaders
        
        // Continue with the modified request
        return try await next.respond(to: request)
    }
}

// Extension for easy registration
extension Application {
    func addHeaderFilterMiddleware() {
        self.middleware.use(HeaderFilterMiddleware())
    }
}

import Vapor
import AsyncHTTPClient

public func configure(_ app: Application) async throws {
    // Configure logging
    if app.environment == .development {
        app.logger.logLevel = .debug
    } else {
        app.logger.logLevel = .info
    }

    // Allow Vapor to larger payload
    app.routes.defaultMaxBodySize = "500kb"

    // Add header filter middleware - filters incoming request headers
    app.addHeaderFilterMiddleware()

    // Register routes
    app.addMistralProxyRoutes()

    // Configure CORS - allow all origins for development
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .DELETE, .PATCH],
        allowedHeaders: [.contentType, .authorization, .accept, .userAgent],
        allowCredentials: true
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfiguration))

    // Error middleware
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))

    // Log startup
    app.logger.info("Mistral Relay starting on port: \(AppConfig.Server.port)")
}

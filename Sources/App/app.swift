import Vapor

public struct App {
    public static func main() async throws {
        // Create the application
        let app = try await Application.make(.production)
        
        // Configure the application
        try await configure(app)
        
        // Run the application
        try await app.execute()
    }
}

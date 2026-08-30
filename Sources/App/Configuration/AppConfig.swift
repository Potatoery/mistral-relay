import Vapor

struct AppConfig {
    struct Mistral {
        static let baseURL = Environment.get("MISTRAL_BASE_URL") ?? "https://api.mistral.ai"
        static let chatCompletionsPath = Environment.get("MISTRAL_COMPLETIONS_PATH") ?? "/v1/chat/completions"
        
        // Headers that are allowed to be forwarded to Mistral API
        // Add more headers here as needed for your use case
        static let allowedHeaders: Set<String> = [
            "content-type",
            "authorization",
            "accept",
            "user-agent",
            "accept-encoding",
            "connection"
        ]
        
        // Headers that should never be forwarded (hop-by-hop headers)
        static let blockedHeaders: Set<String> = [
            "host",
            "content-length",
            "transfer-encoding",
            "keep-alive",
            "proxy-connection",
            "proxy-authenticate",
            "te",
            "trailers"
        ]
    }
    
    struct Server {
        static let port = Environment.get("PORT") ?? "8080"
    }
}

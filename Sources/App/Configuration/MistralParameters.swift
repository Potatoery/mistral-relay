import Vapor

/// Configuration for Mistral API allowed parameters
struct MistralParameters {
    
    /// All allowed request body parameters for /v1/chat/completions endpoint
    /// Based on Mistral API documentation
    static let allowedRequestBodyKeys: Set<String> = [
        "frequency_penalty",
        "guardrails",
        "max_tokens",
        "messages",
        "metadata",
        "model",
        "n",
        "parallel_tool_calls",
        "prediction",
        "presence_penalty",
        "prompt_cache_key",
        "prompt_mode",
        "random_seed",
        "reasoning_effort",
        "response_format",
        "safe_prompt",
        "service_tier",
        "stop",
        "stream",
        "temperature",
        "tool_choice",
        "tools",
        "top_p"
    ]
    
    /// Filter a dictionary to only include allowed keys
    static func filterRequestBody(_ body: [String: Any]) -> [String: Any] {
        var filtered: [String: Any] = [:]
        
        for (key, value) in body {
            if allowedRequestBodyKeys.contains(key) {
                filtered[key] = value
            } else {
                // Log filtered parameter for debugging
                print("Filtering out unsupported parameter: \(key)")
            }
        }
        
        return filtered
    }
}

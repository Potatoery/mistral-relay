import Vapor

/// Configuration for Mistral API allowed parameters
struct MistralParameters {
    
    /// All allowed request body parameters for /v1/chat/completions endpoint
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
    
    /// Allowed keys inside individual message objects within the 'messages' array
    static let allowedMessageKeys: Set<String> = [
        "role",
        "content",
        "name",
        "tool_calls",
        "tool_call_id",
        "prefix"
    ]
    
    /// Filter a dictionary to only include allowed keys, including nested message keys
    static func filterRequestBody(_ body: [String: Any], logger: Logger) -> [String: Any] {
        var filtered: [String: Any] = [:]
        
        for (key, value) in body {
            if allowedRequestBodyKeys.contains(key) {
                if key == "messages", let messages = value as? [[String: Any]] {
                    // messages 배열 내부의 개별 메시지 객체 필드 정제 및 로그 출력
                    filtered[key] = messages.map { message in
                        var cleanedMessage: [String: Any] = [:]
                        for (msgKey, msgValue) in message {
                            if allowedMessageKeys.contains(msgKey) {
                                cleanedMessage[msgKey] = msgValue
                            } else {
                                logger.info("Filtering out unsupported message parameter: \(msgKey)")
                            }
                        }
                        return cleanedMessage
                    }
                } else {
                    filtered[key] = value
                }
            } else {
                logger.info("Filtering out unsupported top-level parameter: \(key)")
            }
        }
        
        return filtered
    }
}

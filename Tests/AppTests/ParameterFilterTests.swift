@testable import App
import XCTest
import Vapor

final class ParameterFilterTests: XCTestCase {
    
    func testFilterRequestBodyKeepsAllowedParameters() {
        let input: [String: Any] = [
            "model": "mistral-large-latest",
            "messages": [
                ["role": "user", "content": "Hello"]
            ],
            "temperature": 0.7,
            "max_tokens": 100,
            "stream": false
        ]
        
        let filtered = MistralParameters.filterRequestBody(input)
        
        // All parameters should be kept (they're all in the allowed list)
        XCTAssertEqual(filtered.count, 5)
        XCTAssertNotNil(filtered["model"])
        XCTAssertNotNil(filtered["messages"])
        XCTAssertNotNil(filtered["temperature"])
        XCTAssertNotNil(filtered["max_tokens"])
        XCTAssertNotNil(filtered["stream"])
    }
    
    func testFilterRequestBodyRemovesUnsupportedParameters() {
        let input: [String: Any] = [
            "model": "mistral-large-latest",
            "messages": [
                ["role": "user", "content": "Hello"]
            ],
            "temperature": 0.7,
            "unsupported_param": "should be removed",
            "another_unknown": 123,
            "custom_field": ["a", "b", "c"]
        ]
        
        let filtered = MistralParameters.filterRequestBody(input)
        
        // Only allowed parameters should remain
        XCTAssertEqual(filtered.count, 3)
        XCTAssertNotNil(filtered["model"])
        XCTAssertNotNil(filtered["messages"])
        XCTAssertNotNil(filtered["temperature"])
        
        // Unsupported parameters should be removed
        XCTAssertNil(filtered["unsupported_param"])
        XCTAssertNil(filtered["another_unknown"])
        XCTAssertNil(filtered["custom_field"])
    }
    
    func testFilterRequestBodyHandlesEmptyInput() {
        let input: [String: Any] = [:]
        let filtered = MistralParameters.filterRequestBody(input)
        XCTAssertTrue(filtered.isEmpty)
    }
    
    func testFilterRequestBodyHandlesNestedObjects() {
        let input: [String: Any] = [
            "model": "mistral-large-latest",
            "messages": [
                ["role": "user", "content": "Hello"]
            ],
            "response_format": [
                "type": "json_object"
            ],
            "unsupported": "value"
        ]
        
        let filtered = MistralParameters.filterRequestBody(input)
        
        XCTAssertEqual(filtered.count, 3)
        XCTAssertNotNil(filtered["model"])
        XCTAssertNotNil(filtered["messages"])
        XCTAssertNotNil(filtered["response_format"])
        XCTAssertNil(filtered["unsupported"])
        
        // Nested objects should be preserved
        if let responseFormat = filtered["response_format"] as? [String: Any] {
            XCTAssertEqual(responseFormat["type"] as? String, "json_object")
        } else {
            XCTFail("response_format should be preserved as nested object")
        }
    }
    
    func testAllMistralParametersAreAllowed() {
        // This test verifies that all documented Mistral parameters are in the allowed list
        let allAllowedKeys = MistralParameters.allowedRequestBodyKeys
        
        let expectedParameters = [
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
        
        for param in expectedParameters {
            XCTAssertTrue(allAllowedKeys.contains(param), 
                         "Parameter 'grand' should be in allowed list")
        }
        
        XCTAssertEqual(allAllowedKeys.count, expectedParameters.count)
    }
}

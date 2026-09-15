# Mistral Relay - Swift Proxy Server

A high-performance, asynchronous Swift-based proxy server that filters unsupported headers and request body parameters, then forwards requests to the official Mistral AI Chat Completion API.

This proxy ensures that:
1. **Only allowed headers** (e.g., authorization, content-type) are forwarded to Mistral.
2. **Only valid Mistral API parameters** in the request body are forwarded.
3. Unsupported parameters/headers are dynamically stripped to prevent API validation errors.

---

## Features

- **Header Filtering**: Only forwards allowed headers to Mistral API.
- **Parameter Filtering**: Only forwards valid Mistral API parameters in the request body.
- **Request Proxy**: Transparent proxy to Mistral's `/v1/chat/completions` endpoint.
- **Health Check**: Built-in health check endpoint (`/health`).
- **CORS Support**: Configurable CORS for development.
- **Docker Ready**: Includes Dockerfile and docker-compose configuration.

---

## Prerequisites

Before starting, ensure you have one of the following installed:
* **Swift 5.9+** (if running locally on macOS/Linux)
* **Docker & Docker Compose** (for containerized deployment)

---

## Quick Start (How to Run)

Choose one of the two execution paths below:

### Option A: Running Locally (Development)

Build the project and run the executable target using Swift Package Manager (SPM):

```bash
# Clone the repository
git clone <repository-url>
cd Mistral-Relay

# Build the application (with zero warnings)
swift build

# Run the server
swift run
```
The server will start and listen on `http://localhost:8080`.

### Option B: Running with Docker (Production/Dockerized)

To build and run the application inside isolated Docker containers:

```bash
# Option 1: Run with Docker Compose (Recommended)
docker-compose up -d --build

# Option 2: Build and run manually with Docker
docker build -t mistral-relay .
docker run -p 8080:8080 --env PORT=8080 mistral-relay
```

---

## Configuration (Environment Variables)

You can dynamically configure the proxy server without changing the source code by setting the following environment variables:

| Environment Variable | Default Value | Description |
| --- | --- | --- |
| `PORT` | `8080` | The port the proxy server listens on. |
| `MISTRAL_BASE_URL` | `https://api.mistral.ai` | The target Mistral AI API base URL to forward requests to. |
| `MISTRAL_COMPLETIONS_PATH` | `/v1/chat/completions` | The specific API path for Chat Completions. |

### Run Example with Custom Environment Variables:

#### Locally:
```bash
export PORT=9000
export MISTRAL_BASE_URL="https://your-custom-gateway.com"
export MISTRAL_COMPLETIONS_PATH="/v1/custom/completions"

swift run
```

#### With Docker:
```bash
docker run -p 9000:9000 \
  --env PORT=9000 \
  --env MISTRAL_BASE_URL="https://your-custom-gateway.com" \
  --env MISTRAL_COMPLETIONS_PATH="/v1/custom/completions" \
  mistral-relay
```

---

## Verification & API Endpoints

### 1. Health Check Endpoint

To check if the proxy server is running and healthy:

```bash
curl -i http://localhost:8080/health
```

**Expected Response (200 OK):**
```http
HTTP/1.1 200 OK
content-length: 2
connection: keep-alive

OK
```

### 2. Chat Completion Proxy Endpoint

```
POST /api/v1/chat/completions
```

Forwards requests to Mistral's Chat Completion API with filtered headers.

**Request Headers:**
- `Content-Type: application/json` (required)
- `Authorization: Bearer <your-mistral-api-key>` (required)
- Other allowed headers (see configuration below)

**Request Body:** Same as Mistral's Chat Completion API.

---

## Step-by-Step Usage Examples

Send your chat requests directly to the proxy at `http://localhost:8080/api/v1/chat/completions` instead of Mistral's endpoint.

### 1. Using cURL
```bash
curl -X POST http://localhost:8080/api/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_MISTRAL_API_KEY" \
  -H "X-Unallowed-Header: arbitrary_value" \
  -d '{
    "model": "mistral-large-latest",
    "messages": [
      {
        "role": "user",
        "content": "Why is the sky blue? Answer in 1 sentence."
      }
    ],
    "unsupported_custom_param": "some_value"
  }'
```

### 2. Using Python
```python
import requests

url = "http://localhost:8080/api/v1/chat/completions"
headers = {
    "Content-Type": "application/json",
    "Authorization": "Bearer YOUR_MISTRAL_API_KEY",
    "X-Client-Identifier": "DevAgent" # Will be stripped out by proxy
}
data = {
    "model": "mistral-large-latest",
    "messages": [{"role": "user", "content": "Explain gravity in one word."}],
    "temperature": 0.3,
    "garbage_parameter": 9999 # Will be stripped out by proxy
}

response = requests.post(url, json=data, headers=headers)
print(response.json())
```

### 3. Using JavaScript (Node.js/Fetch)
```javascript
const response = await fetch("http://localhost:8080/api/v1/chat/completions", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Authorization": "Bearer YOUR_MISTRAL_API_KEY",
    "X-Experimental-Feature": "true" // Stripped
  },
  body: JSON.stringify({
    model: "mistral-large-latest",
    messages: [{ role: "user", content: "Tell me a joke." }],
    stream: false,
    unsupported_key: "value" // Stripped
  })
});

const result = await response.json();
console.log(result);
```

---

## How It Works (Filter Mechanisms)

When a request reaches the proxy, it performs the following filtration pipeline:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Client App    │───▶│   Mistral Relay  │───▶│   Mistral API   │
│                 │    │ (This Server)    │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                          │
                          ▼
                  ┌───────────────────────┐
                  │    Request Filtering   │
                  │  1. Header Filtering   │
                  │     - Allow List       │
                  │     - Block List       │
                  │  2. Parameter Filtering│
                  │     - Mistral API      │
                  │       Parameters Only  │
                  └───────────────────────┘
```

### 1. Header Filter Process
The proxy inspects the incoming headers and matches them against the configuration.
* **Allowed Headers (Forwarded):**
  Only headers in the allow-list are forwarded:
  ```swift
  "content-type", "authorization", "accept", "user-agent", "accept-encoding", "connection"
  ```
* **Blocked Headers (Stripped):**
  Common hop-by-hop headers and non-standard custom headers (e.g., `X-Unallowed-Header`) are quietly stripped:
  ```swift
  "host", "content-length", "transfer-encoding", "keep-alive", "proxy-connection", "proxy-authenticate", "te", "trailers"
  ```

### 2. Body Parameter Filter Process
The JSON body is dynamically parsed. Only official parameters listed in the Mistral API documentation are retained.
* **Retained Parameters (Forwarded):**
  The allowed request body parameters for the `/v1/chat/completions` endpoint are:
  - `frequency_penalty`, `guardrails`, `max_tokens`, `messages`, `metadata`, `model`, `n`, `parallel_tool_calls`, `prediction`, `presence_penalty`, `prompt_cache_key`, `prompt_mode`, `random_seed`, `reasoning_effort`, `response_format`, `safe_prompt`, `service_tier`, `stop`, `stream`, `temperature`, `tool_choice`, `tools`, `top_p`.
* **Stripped Parameters:**
  Any unlisted parameters (such as `unsupported_custom_param`) are logged on the console and removed from the payload before forwarding to Mistral.
* **Sampling Parameter Normalization:**
  When `temperature` is set to `0` (greedy sampling), the Mistral API requires `top_p` to be `1`. The relay automatically raises `temperature` to `0.2` in this case so `top_p` can be kept as-is, preventing a `400 top_p must be 1 when using greedy sampling` error.

---

## Customization Guide

### A. How to Add More Allowed Headers
To allow additional headers (such as tracing headers like `x-request-id` or custom analytics headers), open `Sources/App/Configuration/AppConfig.swift` and update the `allowedHeaders` list:

```swift
// Sources/App/Configuration/AppConfig.swift
struct Mistral {
    static let allowedHeaders: Set<String> = [
        "content-type",
        "authorization",
        "accept",
        "user-agent",
        "accept-encoding",
        "connection",
        "x-request-id"  // <-- Add your new allowed header here (lowercased)
    ]
}
```

### B. How to Allow More Request Parameters
If Mistral releases a new API parameter, or you want to pass a custom field, open `Sources/App/Configuration/MistralParameters.swift` and add it to `allowedRequestBodyKeys`:

```swift
// Sources/App/Configuration/MistralParameters.swift
struct MistralParameters {
    static let allowedRequestBodyKeys: Set<String> = [
        "model",
        "messages",
        "temperature",
        // ...
        "new_mistral_feature"  // <-- Add the new parameter key here
    ]
}
```

### C. How to Add Additional Routes
Add new routes in `MistralProxyController.swift`:

```swift
func boot(routes: RoutesBuilder) throws {
    routes.get("health", use: healthCheck)
    
    // Add custom route
    routes.get("custom", use: customHandler)
    
    let mistralRoutes = routes.grouped("api", "v1", "chat")
    mistralRoutes.post("completions", use: proxyToMistral)
}
```

---

## Project Structure

```
Mistral-Relay/
├── Sources/
│   ├── App/
│   │   ├── Configuration/    # App configurations & filter rule lists
│   │   ├── Controllers/       # Route handlers & proxy controller
│   │   ├── Middleware/        # Header filtration middleware
│   │   ├── app.swift          # Application entry point & setup
│   │   └── configure.swift    # App configurations
│   └── Run/                  # Executable target
│       └── main.swift
├── Tests/
│   └── AppTests/             # Unit test suites (Header & Parameter filtering)
├── Package.swift             # Swift Package Manager manifest
├── Dockerfile                # Docker build configuration
├── docker-compose.yml        # Docker Compose configuration
└── README.md
```

---

## Running Verification Tests

To verify that your filters, proxies, and configurations are executing correctly and conforming to Swift 6 Concurrency standards, execute the unit test suite:

```bash
swift test
```

All 11 tests should pass successfully with zero failures and warnings:
```
Build complete! (4.05 sec)
Executed 11 tests, with 0 failures (0 unexpected) in 0.007 (0.009) seconds
```

---

## Dependencies

- [Vapor 4](https://github.com/vapor/vapor) - Web framework for Swift
- [AsyncHTTPClient](https://github.com/vapor/async-http-client) - Async HTTP client

---

## Acknowledgments

This project was made with AI assistance.

---

## License

This project is licensed under the MIT License.

# BYOM Provider Layer (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One LLM provider layer (Anthropic, OpenAI-compatible, Ollama) with API-key and subscription-OAuth auth, keys in the Keychain, and a Settings UI.

**Architecture:** Pure wire codecs (`Support/LLMWire*.swift`) translate provider-neutral messages/tools to each vendor's HTTP body and parse each vendor's stream into `LLMEvent`s. A single app-side `actor LLMClient` does the networking. A provider registry persists in UserDefaults; secrets persist in the Keychain. Spec: `docs/plans/2026-08-12-ask-mish-byom-design.md`.

**Tech Stack:** Swift 5.10, macOS 14+, SwiftUI, XCTest, CryptoKit. No new package dependencies.

## Global Constraints

- Prose in user-facing strings: short, plain sentences (Ron's STE preference applies to UI copy).
- Every new pure `Support/*.swift` file MUST be added to the `MishMailTests` target `sources:` list in `project.yml` (around line 130) or its tests will not compile.
- Run tests with `make test` (regenerates the Xcode project via xcodegen first). For a single suite after `make test` has run once: `xcodebuild test -project MishMail.xcodeproj -scheme MishMailTests -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd.noindex -only-testing:MishMailTests/<SuiteName>`.
- The pre-commit hook runs the full test suite. Never commit with `--no-verify`.
- Keychain access must go through `Keychain` (Support/Keychain.swift) and must be skipped in fixture processes — reuse `OAuthConfig.usesKeychain(environment:)` (Sources/MishMail/Auth/OAuth.swift:33).
- Endpoint rule: loopback URLs always allowed; non-loopback must be HTTPS.
- Secrets never go in UserDefaults. Only provider metadata does.
- Commit messages: `feat:`/`test:`/`docs:` prefix, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Provider-neutral chat types (`LLMChat.swift`)

**Files:**
- Create: `Sources/MishMail/Support/LLMChat.swift`
- Modify: `project.yml` (MishMailTests `sources:` list, ~line 130)
- Test: `Tests/MishMailTests/LLMChatTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LLMProviderKind`, `LLMAuthMode`, `LLMOAuthVendor`, `LLMProviderConfig`, `LLMRole`, `LLMMessage`, `LLMToolCall`, `LLMToolResult`, `LLMToolSpec`, `LLMUsage`, `LLMEvent`, `LLMEndpoint.validate(_:)`. Every later task uses these exact names.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class LLMChatTests: XCTestCase {
    func testProviderConfigRoundTripsThroughJSON() throws {
        let config = LLMProviderConfig(
            id: UUID(), kind: .anthropic, label: "Claude",
            baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-5",
            authMode: .oauth(.claude))
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(LLMProviderConfig.self, from: data)
        XCTAssertEqual(back, config)
    }

    func testEndpointValidationAllowsLoopbackHTTP() throws {
        try LLMEndpoint.validate(URL(string: "http://127.0.0.1:11434/api/chat")!)
        try LLMEndpoint.validate(URL(string: "http://localhost:11434")!)
    }

    func testEndpointValidationRejectsRemoteHTTP() {
        XCTAssertThrowsError(try LLMEndpoint.validate(URL(string: "http://api.x.ai/v1")!))
    }

    func testEndpointValidationAllowsRemoteHTTPS() throws {
        try LLMEndpoint.validate(URL(string: "https://api.x.ai/v1")!)
    }
}
```

- [ ] **Step 2: Add both files to `project.yml` and run the test to verify it fails**

Add to the MishMailTests `sources:` list (keep alphabetical-ish grouping with the other Support entries):

```yaml
      - Sources/MishMail/Support/LLMChat.swift
```

Run: `make test`
Expected: FAIL — `cannot find 'LLMProviderConfig' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Provider-neutral chat types shared by all LLM wire codecs and the client.
/// Pure data — no networking here.

enum LLMProviderKind: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openAICompatible
    case ollama
}

enum LLMOAuthVendor: String, Codable, Sendable {
    case claude
    case chatGPT
}

enum LLMAuthMode: Codable, Equatable, Sendable {
    case apiKey
    case oauth(LLMOAuthVendor)
}

struct LLMProviderConfig: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: LLMProviderKind
    var label: String
    var baseURL: String
    var defaultModel: String
    var authMode: LLMAuthMode
}

enum LLMRole: String, Codable, Sendable { case system, user, assistant, tool }

struct LLMToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Raw JSON object string of the tool arguments.
    var argumentsJSON: String
}

struct LLMToolResult: Codable, Equatable, Sendable {
    var callID: String
    /// Raw JSON (or plain text) content returned by the tool.
    var content: String
    var isError: Bool
}

struct LLMMessage: Codable, Equatable, Sendable {
    var role: LLMRole
    var text: String
    var toolCalls: [LLMToolCall] = []
    var toolResults: [LLMToolResult] = []

    init(role: LLMRole, text: String,
         toolCalls: [LLMToolCall] = [], toolResults: [LLMToolResult] = []) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }
}

struct LLMToolSpec: Equatable, Sendable {
    var name: String
    var description: String
    /// Raw JSON Schema object string for the tool input.
    var inputSchemaJSON: String
}

struct LLMUsage: Codable, Equatable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
}

enum LLMEvent: Equatable, Sendable {
    case token(String)
    case toolCall(LLMToolCall)
    case done(stopReason: String, usage: LLMUsage?)
}

/// Endpoint rule shared by every provider: loopback is always allowed;
/// anything remote must be HTTPS. Mail content never travels cleartext.
enum LLMEndpoint {
    enum ValidationError: LocalizedError, Equatable {
        case insecure(String)
        var errorDescription: String? {
            switch self {
            case .insecure(let url):
                return "Endpoint \(url) is neither local nor HTTPS. Use a local URL or an https:// URL."
            }
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static func validate(_ url: URL) throws {
        if isLoopback(url) { return }
        if url.scheme?.lowercased() != "https" {
            throw ValidationError.insecure(url.absoluteString)
        }
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `make test`
Expected: PASS (all suites, including the new `LLMChatTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/Support/LLMChat.swift Tests/MishMailTests/LLMChatTests.swift project.yml
git commit -m "feat: provider-neutral LLM chat types and endpoint rule

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: OpenAI-compatible wire codec (`LLMWireOpenAI.swift`)

Covers OpenAI, OpenRouter, Groq, xAI Grok (`https://api.x.ai/v1`), LM Studio.

**Files:**
- Create: `Sources/MishMail/Support/LLMWireOpenAI.swift`
- Modify: `project.yml` (add the file to MishMailTests `sources:`)
- Test: `Tests/MishMailTests/LLMWireOpenAITests.swift`

**Interfaces:**
- Consumes: `LLMMessage`, `LLMToolSpec`, `LLMEvent`, `LLMToolCall`, `LLMUsage` from Task 1.
- Produces: `OpenAIWire.requestBody(model:messages:tools:) throws -> Data` and `OpenAIWire.StreamState` with `mutating func consume(line: String) -> [LLMEvent]`. Task 6 (`LLMClient`) calls both.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class LLMWireOpenAITests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRequestBodyMapsRolesToolCallsAndResults() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: "be brief"),
            LLMMessage(role: .user, text: "hi"),
            LLMMessage(role: .assistant, text: "",
                       toolCalls: [LLMToolCall(id: "c1", name: "search_threads",
                                               argumentsJSON: #"{"query":"acme"}"#)]),
            LLMMessage(role: .tool, text: "",
                       toolResults: [LLMToolResult(callID: "c1", content: "[]", isError: false)]),
        ]
        let tools = [LLMToolSpec(name: "search_threads", description: "Search mail",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let body = try decode(try OpenAIWire.requestBody(
            model: "grok-4-0709", messages: messages, tools: tools))

        XCTAssertEqual(body["model"] as? String, "grok-4-0709")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let wireMessages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(wireMessages.map { $0["role"] as! String },
                       ["system", "user", "assistant", "tool"])
        let call = ((wireMessages[2]["tool_calls"] as! [[String: Any]])[0])
        XCTAssertEqual(call["id"] as? String, "c1")
        XCTAssertEqual((call["function"] as! [String: Any])["name"] as? String, "search_threads")
        XCTAssertEqual(wireMessages[3]["tool_call_id"] as? String, "c1")
        let toolDef = (body["tools"] as! [[String: Any]])[0]["function"] as! [String: Any]
        XCTAssertEqual(toolDef["name"] as? String, "search_threads")
    }

    func testStreamTokensThenDoneWithUsage() {
        var state = OpenAIWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        events += state.consume(line: #"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}"#)
        events += state.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#)
        events += state.consume(line: "data: [DONE]")
        XCTAssertEqual(events, [
            .token("Hel"), .token("lo"),
            .done(stopReason: "stop", usage: LLMUsage(promptTokens: 12, completionTokens: 3)),
        ])
    }

    func testStreamAccumulatesChunkedToolCall() {
        var state = OpenAIWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c9","function":{"name":"get_thread","arguments":""}}]}}]}"#)
        events += state.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"id\":"}}]}}]}"#)
        events += state.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"t1\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        events += state.consume(line: "data: [DONE]")
        XCTAssertEqual(events, [
            .toolCall(LLMToolCall(id: "c9", name: "get_thread", argumentsJSON: #"{"id":"t1"}"#)),
            .done(stopReason: "tool_calls", usage: nil),
        ])
    }

    func testNonDataLinesAreIgnored() {
        var state = OpenAIWire.StreamState()
        XCTAssertEqual(state.consume(line: ""), [])
        XCTAssertEqual(state.consume(line: ": keep-alive"), [])
    }
}
```

- [ ] **Step 2: Add to `project.yml`, run to verify failure**

Run: `make test`
Expected: FAIL — `cannot find 'OpenAIWire' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pure codec for the OpenAI Chat Completions wire format (SSE streaming).
/// Also speaks for OpenRouter, Groq, xAI Grok, and LM Studio.
enum OpenAIWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec]) throws -> Data {
        var wireMessages: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                wireMessages.append(["role": "system", "content": message.text])
            case .user:
                wireMessages.append(["role": "user", "content": message.text])
            case .assistant:
                var m: [String: Any] = ["role": "assistant", "content": message.text]
                if !message.toolCalls.isEmpty {
                    m["tool_calls"] = message.toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": call.argumentsJSON]]
                    }
                }
                wireMessages.append(m)
            case .tool:
                for result in message.toolResults {
                    wireMessages.append(["role": "tool",
                                         "tool_call_id": result.callID,
                                         "content": result.content])
                }
            }
        }
        var body: [String: Any] = [
            "model": model,
            "messages": wireMessages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(
                    with: Data(tool.inputSchemaJSON.utf8))
                return ["type": "function",
                        "function": ["name": tool.name,
                                     "description": tool.description,
                                     "parameters": schema]]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Incremental SSE parser. Feed each line; collect events. Tool-call
    /// argument fragments accumulate by index until finish_reason arrives.
    struct StreamState {
        private struct PartialCall { var id = ""; var name = ""; var args = "" }
        private var partial: [Int: PartialCall] = [:]
        private var stopReason = "stop"
        private var usage: LLMUsage?
        private var pendingToolEvents: [LLMEvent] = []

        mutating func consume(line: String) -> [LLMEvent] {
            guard line.hasPrefix("data: ") else { return [] }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
                let events = pendingToolEvents + [LLMEvent.done(stopReason: stopReason, usage: usage)]
                pendingToolEvents = []
                return events
            }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            if let u = object["usage"] as? [String: Any],
               let prompt = u["prompt_tokens"] as? Int,
               let completion = u["completion_tokens"] as? Int {
                usage = LLMUsage(promptTokens: prompt, completionTokens: completion)
            }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
            var events: [LLMEvent] = []
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    events.append(.token(text))
                }
                for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = fragment["index"] as? Int ?? 0
                    var call = partial[index] ?? PartialCall()
                    if let id = fragment["id"] as? String { call.id = id }
                    if let function = fragment["function"] as? [String: Any] {
                        if let name = function["name"] as? String { call.name = name }
                        if let args = function["arguments"] as? String { call.args += args }
                    }
                    partial[index] = call
                }
            }
            if let reason = choice["finish_reason"] as? String {
                stopReason = reason
                if reason == "tool_calls" {
                    for index in partial.keys.sorted() {
                        let call = partial[index]!
                        pendingToolEvents.append(.toolCall(LLMToolCall(
                            id: call.id, name: call.name, argumentsJSON: call.args)))
                    }
                    partial = [:]
                }
            }
            return events
        }
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/Support/LLMWireOpenAI.swift Tests/MishMailTests/LLMWireOpenAITests.swift project.yml
git commit -m "feat: OpenAI-compatible wire codec with streaming tool calls

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Anthropic wire codec (`LLMWireAnthropic.swift`)

**Files:**
- Create: `Sources/MishMail/Support/LLMWireAnthropic.swift`
- Modify: `project.yml` (add to MishMailTests `sources:`)
- Test: `Tests/MishMailTests/LLMWireAnthropicTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `AnthropicWire.requestBody(model:messages:tools:maxTokens:) throws -> Data` and `AnthropicWire.StreamState` with `mutating func consume(line: String) -> [LLMEvent]`. Task 6 calls both.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class LLMWireAnthropicTests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testRequestBodyHoistsSystemAndMapsToolBlocks() throws {
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, text: "be brief"),
            LLMMessage(role: .user, text: "hi"),
            LLMMessage(role: .assistant, text: "checking",
                       toolCalls: [LLMToolCall(id: "tu1", name: "get_thread",
                                               argumentsJSON: #"{"id":"t1"}"#)]),
            LLMMessage(role: .tool, text: "",
                       toolResults: [LLMToolResult(callID: "tu1", content: "{}", isError: true)]),
        ]
        let tools = [LLMToolSpec(name: "get_thread", description: "Get one thread",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let body = try decode(try AnthropicWire.requestBody(
            model: "claude-sonnet-5", messages: messages, tools: tools, maxTokens: 4096))

        XCTAssertEqual(body["system"] as? String, "be brief")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        let wireMessages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(wireMessages.count, 3) // system hoisted out
        let assistantContent = wireMessages[1]["content"] as! [[String: Any]]
        XCTAssertEqual(assistantContent[0]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[1]["type"] as? String, "tool_use")
        XCTAssertEqual(assistantContent[1]["id"] as? String, "tu1")
        let resultContent = wireMessages[2]["content"] as! [[String: Any]]
        XCTAssertEqual(resultContent[0]["type"] as? String, "tool_result")
        XCTAssertEqual(resultContent[0]["tool_use_id"] as? String, "tu1")
        XCTAssertEqual(resultContent[0]["is_error"] as? Bool, true)
        let toolDef = (body["tools"] as! [[String: Any]])[0]
        XCTAssertEqual(toolDef["name"] as? String, "get_thread")
        XCTAssertNotNil(toolDef["input_schema"])
    }

    func testStreamTextThenToolUseThenDone() {
        var state = AnthropicWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"data: {"type":"message_start","message":{"usage":{"input_tokens":20}}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"tu2","name":"search_threads"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"\"acme\"}"}}"#)
        events += state.consume(line: #"data: {"type":"content_block_stop"}"#)
        events += state.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#)
        events += state.consume(line: #"data: {"type":"message_stop"}"#)
        XCTAssertEqual(events, [
            .token("Hi"),
            .toolCall(LLMToolCall(id: "tu2", name: "search_threads",
                                  argumentsJSON: #"{"query":"acme"}"#)),
            .done(stopReason: "tool_use",
                  usage: LLMUsage(promptTokens: 20, completionTokens: 9)),
        ])
    }

    func testEventAndBlankLinesAreIgnored() {
        var state = AnthropicWire.StreamState()
        XCTAssertEqual(state.consume(line: "event: content_block_delta"), [])
        XCTAssertEqual(state.consume(line: ""), [])
    }
}
```

- [ ] **Step 2: Add to `project.yml`, run to verify failure**

Run: `make test`
Expected: FAIL — `cannot find 'AnthropicWire' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pure codec for the Anthropic Messages API (SSE streaming, tool use).
enum AnthropicWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec], maxTokens: Int) throws -> Data {
        var system = ""
        var wireMessages: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                system = message.text
            case .user:
                wireMessages.append(["role": "user",
                                     "content": [["type": "text", "text": message.text]]])
            case .assistant:
                var content: [[String: Any]] = []
                if !message.text.isEmpty {
                    content.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    let input = (try? JSONSerialization.jsonObject(
                        with: Data(call.argumentsJSON.utf8))) ?? [:]
                    content.append(["type": "tool_use", "id": call.id,
                                    "name": call.name, "input": input])
                }
                wireMessages.append(["role": "assistant", "content": content])
            case .tool:
                let content: [[String: Any]] = message.toolResults.map { result in
                    ["type": "tool_result", "tool_use_id": result.callID,
                     "content": result.content, "is_error": result.isError]
                }
                wireMessages.append(["role": "user", "content": content])
            }
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": wireMessages,
            "stream": true,
        ]
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description,
                 "input_schema": try JSONSerialization.jsonObject(
                    with: Data(tool.inputSchemaJSON.utf8))]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    struct StreamState {
        private var toolID = ""
        private var toolName = ""
        private var toolArgs = ""
        private var inToolBlock = false
        private var promptTokens = 0
        private var completionTokens = 0
        private var stopReason = "end_turn"

        mutating func consume(line: String) -> [LLMEvent] {
            guard line.hasPrefix("data: "),
                  let data = String(line.dropFirst(6)).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { return [] }
            switch type {
            case "message_start":
                if let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int {
                    promptTokens = input
                }
                return []
            case "content_block_start":
                if let block = object["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use" {
                    inToolBlock = true
                    toolID = block["id"] as? String ?? ""
                    toolName = block["name"] as? String ?? ""
                    toolArgs = ""
                }
                return []
            case "content_block_delta":
                guard let delta = object["delta"] as? [String: Any] else { return [] }
                if let text = delta["text"] as? String, !text.isEmpty {
                    return [.token(text)]
                }
                if let partial = delta["partial_json"] as? String {
                    toolArgs += partial
                }
                return []
            case "content_block_stop":
                guard inToolBlock else { return [] }
                inToolBlock = false
                let call = LLMToolCall(id: toolID, name: toolName,
                                       argumentsJSON: toolArgs.isEmpty ? "{}" : toolArgs)
                return [.toolCall(call)]
            case "message_delta":
                if let delta = object["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if let usage = object["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    completionTokens = output
                }
                return []
            case "message_stop":
                return [.done(stopReason: stopReason,
                              usage: LLMUsage(promptTokens: promptTokens,
                                              completionTokens: completionTokens))]
            default:
                return []
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/Support/LLMWireAnthropic.swift Tests/MishMailTests/LLMWireAnthropicTests.swift project.yml
git commit -m "feat: Anthropic Messages wire codec with streaming tool use

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Ollama chat wire codec (`LLMWireOllama.swift`)

The existing `Ollama.swift` `/api/generate` path stays untouched (Phase 3 migrates its callers). This codec speaks `/api/chat` — the endpoint that supports messages and tools.

**Files:**
- Create: `Sources/MishMail/Support/LLMWireOllama.swift`
- Modify: `project.yml` (add to MishMailTests `sources:`)
- Test: `Tests/MishMailTests/LLMWireOllamaTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `OllamaChatWire.requestBody(model:messages:tools:) throws -> Data` and `OllamaChatWire.StreamState` with `mutating func consume(line: String) -> [LLMEvent]`. Task 6 calls both.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class LLMWireOllamaTests: XCTestCase {
    func testRequestBodyMapsMessagesAndTools() throws {
        let messages = [LLMMessage(role: .user, text: "hi")]
        let tools = [LLMToolSpec(name: "list_threads", description: "List",
                                 inputSchemaJSON: #"{"type":"object"}"#)]
        let body = try JSONSerialization.jsonObject(with: try OllamaChatWire.requestBody(
            model: "llama3.2", messages: messages, tools: tools)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "llama3.2")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as! [[String: Any]])[0]["content"] as? String, "hi")
        let function = ((body["tools"] as! [[String: Any]])[0]["function"]) as! [String: Any]
        XCTAssertEqual(function["name"] as? String, "list_threads")
    }

    func testStreamTokensToolCallAndDoneWithUsage() {
        var state = OllamaChatWire.StreamState()
        var events: [LLMEvent] = []
        events += state.consume(line: #"{"message":{"role":"assistant","content":"He"},"done":false}"#)
        events += state.consume(line: #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"list_threads","arguments":{"limit":5}}}]},"done":false}"#)
        events += state.consume(line: #"{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":15,"eval_count":4}"#)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .token("He"))
        guard case .toolCall(let call) = events[1] else { return XCTFail("expected toolCall") }
        XCTAssertEqual(call.name, "list_threads")
        XCTAssertEqual(call.id, "call_0") // Ollama has no ids; codec synthesizes them
        let args = try! JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) as! [String: Any]
        XCTAssertEqual(args["limit"] as? Int, 5)
        XCTAssertEqual(events[2], .done(stopReason: "stop",
                                        usage: LLMUsage(promptTokens: 15, completionTokens: 4)))
    }
}
```

- [ ] **Step 2: Add to `project.yml`, run to verify failure**

Run: `make test`
Expected: FAIL — `cannot find 'OllamaChatWire' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pure codec for Ollama's /api/chat NDJSON streaming format.
enum OllamaChatWire {
    static func requestBody(model: String, messages: [LLMMessage],
                            tools: [LLMToolSpec]) throws -> Data {
        var wireMessages: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system, .user, .assistant:
                wireMessages.append(["role": message.role.rawValue,
                                     "content": message.text])
            case .tool:
                for result in message.toolResults {
                    wireMessages.append(["role": "tool", "content": result.content])
                }
            }
        }
        var body: [String: Any] = ["model": model, "messages": wireMessages, "stream": true]
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": ["name": tool.name,
                              "description": tool.description,
                              "parameters": try JSONSerialization.jsonObject(
                                with: Data(tool.inputSchemaJSON.utf8))]]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    struct StreamState {
        private var callCount = 0

        mutating func consume(line: String) -> [LLMEvent] {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [] }
            var events: [LLMEvent] = []
            if let message = object["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    events.append(.token(text))
                }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }
                    let arguments = function["arguments"] ?? [String: Any]()
                    let argsData = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
                    events.append(.toolCall(LLMToolCall(
                        id: "call_\(callCount)", name: name,
                        argumentsJSON: String(decoding: argsData, as: UTF8.self))))
                    callCount += 1
                }
            }
            if object["done"] as? Bool == true {
                var usage: LLMUsage?
                if let prompt = object["prompt_eval_count"] as? Int,
                   let completion = object["eval_count"] as? Int {
                    usage = LLMUsage(promptTokens: prompt, completionTokens: completion)
                }
                events.append(.done(stopReason: "stop", usage: usage))
            }
            return events
        }
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/Support/LLMWireOllama.swift Tests/MishMailTests/LLMWireOllamaTests.swift project.yml
git commit -m "feat: Ollama /api/chat wire codec

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Provider registry and per-task assignments (`LLMProviderStore.swift`)

**Files:**
- Create: `Sources/MishMail/Support/LLMProviderStore.swift`
- Modify: `project.yml` (add to MishMailTests `sources:`)
- Test: `Tests/MishMailTests/LLMProviderStoreTests.swift`

**Interfaces:**
- Consumes: `LLMProviderConfig`, `LLMProviderKind`, `LLMAuthMode` from Task 1; `Ollama.baseURL`/`Ollama.model` (existing statics) for the built-in row.
- Produces: `LLMProviderStore.load(from:)`, `.save(_:to:)`, `.keychainKey(for:)`, `.oauthKeychainKey(for:)`, `.builtInOllama()`, `LLMTask` enum, `LLMTaskAssignment`, `.assignment(for:from:)`, `.setAssignment(_:for:to:)`. Tasks 6 and 9 (and every Phase 2/3 call site) use these.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class LLMProviderStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LLMProviderStoreTests")!
        defaults.removePersistentDomain(forName: "LLMProviderStoreTests")
    }

    func testLoadWithNothingStoredReturnsBuiltInOllamaRow() {
        let providers = LLMProviderStore.load(from: defaults)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].kind, .ollama)
        XCTAssertEqual(providers[0].id, LLMProviderStore.builtInOllamaID)
    }

    func testSaveThenLoadRoundTripsAndKeepsOllamaRow() {
        let grok = LLMProviderConfig(
            id: UUID(), kind: .openAICompatible, label: "Grok",
            baseURL: "https://api.x.ai/v1", defaultModel: "grok-4-0709",
            authMode: .apiKey)
        LLMProviderStore.save([grok], to: defaults)
        let loaded = LLMProviderStore.load(from: defaults)
        XCTAssertTrue(loaded.contains(grok))
        XCTAssertTrue(loaded.contains { $0.kind == .ollama })
    }

    func testKeychainKeyNamesDeriveFromID() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(LLMProviderStore.keychainKey(for: id),
                       "llm.key.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(LLMProviderStore.oauthKeychainKey(for: id),
                       "llm.oauth.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    func testTaskAssignmentDefaultsToBuiltInOllamaAndRoundTrips() {
        let unset = LLMProviderStore.assignment(for: .drafts, from: defaults)
        XCTAssertEqual(unset.providerID, LLMProviderStore.builtInOllamaID)
        let custom = LLMTaskAssignment(providerID: UUID(), model: "claude-sonnet-5")
        LLMProviderStore.setAssignment(custom, for: .drafts, to: defaults)
        XCTAssertEqual(LLMProviderStore.assignment(for: .drafts, from: defaults), custom)
    }
}
```

- [ ] **Step 2: Add to `project.yml`, run to verify failure**

Run: `make test`
Expected: FAIL — `cannot find 'LLMProviderStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Which app feature a model call belongs to. Each task can use a
/// different provider/model (cheap local triage, hosted drafting).
enum LLMTask: String, CaseIterable, Sendable {
    case drafts, summaries, triage, askMish
}

struct LLMTaskAssignment: Codable, Equatable, Sendable {
    var providerID: UUID
    var model: String
}

/// Persists provider metadata in UserDefaults (never secrets — those live
/// in the Keychain under names derived here) and per-task model choices.
enum LLMProviderStore {
    static let defaultsKey = "llm.providers"
    /// Stable id for the built-in Ollama row so task assignments and
    /// defaults survive re-creation.
    static let builtInOllamaID = UUID(uuidString: "00000000-0000-0000-0000-00000000011A")!

    static func builtInOllama() -> LLMProviderConfig {
        LLMProviderConfig(id: builtInOllamaID, kind: .ollama, label: "Ollama (local)",
                          baseURL: Ollama.baseURL, defaultModel: Ollama.model,
                          authMode: .apiKey)
    }

    /// The built-in Ollama row is always present and always reflects the
    /// live `Ollama` settings; stored rows never shadow it.
    static func load(from defaults: UserDefaults = .standard) -> [LLMProviderConfig] {
        var providers: [LLMProviderConfig] = []
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([LLMProviderConfig].self, from: data) {
            providers = stored.filter { $0.id != builtInOllamaID }
        }
        return providers + [builtInOllama()]
    }

    static func save(_ providers: [LLMProviderConfig],
                     to defaults: UserDefaults = .standard) {
        let stored = providers.filter { $0.id != builtInOllamaID }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func keychainKey(for id: UUID) -> String { "llm.key.\(id.uuidString)" }
    static func oauthKeychainKey(for id: UUID) -> String { "llm.oauth.\(id.uuidString)" }

    static func assignmentKey(for task: LLMTask) -> String { "llm.task.\(task.rawValue)" }

    static func assignment(for task: LLMTask,
                           from defaults: UserDefaults = .standard) -> LLMTaskAssignment {
        if let data = defaults.data(forKey: assignmentKey(for: task)),
           let stored = try? JSONDecoder().decode(LLMTaskAssignment.self, from: data) {
            return stored
        }
        return LLMTaskAssignment(providerID: builtInOllamaID, model: Ollama.model)
    }

    static func setAssignment(_ assignment: LLMTaskAssignment, for task: LLMTask,
                              to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(assignment) {
            defaults.set(data, forKey: assignmentKey(for: task))
        }
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/Support/LLMProviderStore.swift Tests/MishMailTests/LLMProviderStoreTests.swift project.yml
git commit -m "feat: LLM provider registry and per-task model assignments

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: OAuth PKCE helpers and vendor constants (`LLMOAuth.swift`)

Pure module: PKCE generation, authorize-URL construction, token form bodies, token JSON parsing, expiry check. The loopback listener and browser hand-off are Task 7.

**Files:**
- Create: `Sources/MishMail/Support/LLMOAuth.swift`
- Modify: `project.yml` (add to MishMailTests `sources:`)
- Test: `Tests/MishMailTests/LLMOAuthTests.swift`

**Interfaces:**
- Consumes: `LLMOAuthVendor` from Task 1.
- Produces: `LLMOAuth.PKCE` (`verifier`, `challenge`, `generate()`), `LLMOAuth.constants(for:)` → `Constants{authorizeURL, tokenURL, clientID, scopes, redirectPath}`, `LLMOAuth.authorizeURL(vendor:redirectURI:state:challenge:)`, `LLMOAuth.tokenRequestForm(vendor:code:verifier:redirectURI:)`, `LLMOAuth.refreshRequestForm(vendor:refreshToken:)`, `LLMOAuth.parseTokens(from:now:)` → `LLMOAuthTokens{accessToken, refreshToken, expiresAt}` (Codable), `LLMOAuthTokens.isExpired(now:)`. Tasks 7 and 8 use these.

**IMPORTANT — verify vendor constants before implementing.** OAuth constants drift. The values below are the publicly known Claude Code / Codex CLI flows (the same flows Aside uses). Before Step 3, check them against a current open-source client (e.g. the OpenCode or opencode-style repos, or Aside release notes). If sign-in cannot be made to work, keep the module compiling and let the Settings UI (Task 8) degrade to API-key mode — that path is required by the spec either way.

- Claude: authorize `https://claude.ai/oauth/authorize`, token `https://console.anthropic.com/v1/oauth/token`, client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, scopes `org:create_api_key user:profile user:inference`.
- ChatGPT: authorize `https://auth.openai.com/oauth/authorize`, token `https://auth.openai.com/oauth/token`, client id `app_EMoamEEZ73f0CkXaXp7hrann`, scopes `openid profile email offline_access`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class LLMOAuthTests: XCTestCase {
    func testPKCEGeneratesURLSafeVerifierAndS256Challenge() {
        let pkce = LLMOAuth.PKCE.generate()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertFalse(pkce.challenge.contains("="))
        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        // Deterministic check against a known vector (RFC 7636 appendix B).
        let known = LLMOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(known.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLCarriesRequiredParameters() throws {
        let url = LLMOAuth.authorizeURL(
            vendor: .claude, redirectURI: "http://127.0.0.1:53682/callback",
            state: "st8", challenge: "ch4")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["state"], "st8")
        XCTAssertEqual(query["code_challenge"], "ch4")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:53682/callback")
        XCTAssertEqual(query["client_id"], LLMOAuth.constants(for: .claude).clientID)
    }

    func testParseTokensComputesExpiry() throws {
        let json = #"{"access_token":"at1","refresh_token":"rt1","expires_in":3600}"#
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try LLMOAuth.parseTokens(from: Data(json.utf8), now: now)
        XCTAssertEqual(tokens.accessToken, "at1")
        XCTAssertEqual(tokens.refreshToken, "rt1")
        XCTAssertFalse(tokens.isExpired(now: now))
        XCTAssertTrue(tokens.isExpired(now: now.addingTimeInterval(3600)))
    }

    func testRefreshFormContainsGrantAndClient() {
        let form = LLMOAuth.refreshRequestForm(vendor: .chatGPT, refreshToken: "rt9")
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "rt9")
        XCTAssertEqual(form["client_id"], LLMOAuth.constants(for: .chatGPT).clientID)
    }
}
```

- [ ] **Step 2: Add to `project.yml`, run to verify failure**

Run: `make test`
Expected: FAIL — `cannot find 'LLMOAuth' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import CryptoKit
import Foundation

/// Subscription OAuth for LLM providers (sign in with Claude / ChatGPT),
/// the way the Aside browser does it. Pure: URL/form/JSON math only.
/// The loopback listener and browser hand-off live in LLMOAuthFlow.
enum LLMOAuth {
    struct Constants {
        let authorizeURL: String
        let tokenURL: String
        let clientID: String
        let scopes: String
        let redirectPath: String
    }

    /// Publicly known Claude Code / Codex CLI flow constants. Verified at
    /// implementation time; if a vendor changes them, sign-in fails softly
    /// and the UI falls back to API-key mode.
    static func constants(for vendor: LLMOAuthVendor) -> Constants {
        switch vendor {
        case .claude:
            return Constants(
                authorizeURL: "https://claude.ai/oauth/authorize",
                tokenURL: "https://console.anthropic.com/v1/oauth/token",
                clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                scopes: "org:create_api_key user:profile user:inference",
                redirectPath: "/callback")
        case .chatGPT:
            return Constants(
                authorizeURL: "https://auth.openai.com/oauth/authorize",
                tokenURL: "https://auth.openai.com/oauth/token",
                clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                scopes: "openid profile email offline_access",
                redirectPath: "/callback")
        }
    }

    struct PKCE {
        let verifier: String
        var challenge: String {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return Data(digest).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func generate() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let verifier = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return PKCE(verifier: verifier)
        }
    }

    static func authorizeURL(vendor: LLMOAuthVendor, redirectURI: String,
                             state: String, challenge: String) -> URL {
        let constants = constants(for: vendor)
        var components = URLComponents(string: constants.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: constants.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: constants.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    static func tokenRequestForm(vendor: LLMOAuthVendor, code: String,
                                 verifier: String, redirectURI: String) -> [String: String] {
        ["grant_type": "authorization_code",
         "code": code,
         "code_verifier": verifier,
         "redirect_uri": redirectURI,
         "client_id": constants(for: vendor).clientID]
    }

    static func refreshRequestForm(vendor: LLMOAuthVendor,
                                   refreshToken: String) -> [String: String] {
        ["grant_type": "refresh_token",
         "refresh_token": refreshToken,
         "client_id": constants(for: vendor).clientID]
    }

    static func parseTokens(from data: Data, now: Date) throws -> LLMOAuthTokens {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return LLMOAuthTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? "",
            expiresAt: now.addingTimeInterval(TimeInterval(response.expires_in ?? 3600)))
    }
}

struct LLMOAuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// A 60-second safety margin so a token that expires mid-request
    /// refreshes up front instead.
    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt.addingTimeInterval(-60)
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/Support/LLMOAuth.swift Tests/MishMailTests/LLMOAuthTests.swift project.yml
git commit -m "feat: PKCE helpers and vendor constants for LLM subscription OAuth

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Streaming client and OAuth flow (`LLMClient.swift`, app target only)

Thin IO around the tested codecs. Not unit-tested (network + Keychain); the pure logic is already covered by Tasks 1–6. Do NOT add this file to the MishMailTests sources.

**Files:**
- Create: `Sources/MishMail/Support/LLMClient.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6; `Keychain.read`/`.set` (Support/Keychain.swift); `OAuthConfig.usesKeychain(environment:)` (Auth/OAuth.swift:33); `OAuthService().startLoopbackListener(expectedState:)` (Auth/OAuth.swift:239 — returns `(UInt16, Task<String, Error>)` where the task resolves to the authorization code).
- Produces:
  - `actor LLMClient` with `func stream(messages: [LLMMessage], tools: [LLMToolSpec], config: LLMProviderConfig, model: String) -> AsyncThrowingStream<LLMEvent, Error>` and `func listModels(config: LLMProviderConfig) async throws -> [String]`.
  - `@MainActor enum LLMOAuthFlow` with `static func signIn(vendor: LLMOAuthVendor, providerID: UUID) async throws`.
  - `enum LLMClientError: LocalizedError` with cases `missingCredential`, `http(Int)`, `keychainUnavailable`.
  Phase 2/3 call sites and Task 8's UI use these exact signatures.

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import Foundation

enum LLMClientError: LocalizedError {
    case missingCredential
    case http(Int)
    case keychainUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "No API key or sign-in for this provider. Add one in Settings → AI."
        case .http(let code):
            return "The model provider returned HTTP \(code)."
        case .keychainUnavailable:
            return "Keychain is unavailable. Unlock your Mac and try again."
        }
    }
}

/// One streaming client for every provider kind. Builds requests with the
/// pure wire codecs, streams SSE/NDJSON lines through the matching
/// StreamState, refreshes OAuth tokens on 401 (single retry).
actor LLMClient {
    static let shared = LLMClient()

    func stream(messages: [LLMMessage], tools: [LLMToolSpec],
                config: LLMProviderConfig, model: String) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages: messages, tools: tools, config: config,
                                       model: model, allowRefresh: true) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(messages: [LLMMessage], tools: [LLMToolSpec],
                     config: LLMProviderConfig, model: String, allowRefresh: Bool,
                     yield: @Sendable (LLMEvent) -> Void) async throws {
        let request = try await buildRequest(messages: messages, tools: tools,
                                             config: config, model: model)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, allowRefresh, case .oauth(let vendor) = config.authMode {
            try await refreshTokens(vendor: vendor, providerID: config.id)
            return try await run(messages: messages, tools: tools, config: config,
                                 model: model, allowRefresh: false, yield: yield)
        }
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }

        switch config.kind {
        case .openAICompatible:
            var state = OpenAIWire.StreamState()
            for try await line in bytes.lines { state.consume(line: line).forEach(yield) }
        case .anthropic:
            var state = AnthropicWire.StreamState()
            for try await line in bytes.lines { state.consume(line: line).forEach(yield) }
        case .ollama:
            var state = OllamaChatWire.StreamState()
            for try await line in bytes.lines { state.consume(line: line).forEach(yield) }
        }
    }

    private func buildRequest(messages: [LLMMessage], tools: [LLMToolSpec],
                              config: LLMProviderConfig, model: String) async throws -> URLRequest {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        let path: String
        let body: Data
        switch config.kind {
        case .openAICompatible:
            path = base.hasSuffix("/v1") ? "\(base)/chat/completions" : "\(base)/v1/chat/completions"
            body = try OpenAIWire.requestBody(model: model, messages: messages, tools: tools)
        case .anthropic:
            path = "\(base)/v1/messages"
            body = try AnthropicWire.requestBody(model: model, messages: messages,
                                                 tools: tools, maxTokens: 8192)
        case .ollama:
            path = "\(base)/api/chat"
            body = try OllamaChatWire.requestBody(model: model, messages: messages, tools: tools)
        }
        guard let url = URL(string: path) else { throw LLMClientError.http(0) }
        try LLMEndpoint.validate(url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try applyAuth(to: &request, config: config)
        return request
    }

    private func applyAuth(to request: inout URLRequest, config: LLMProviderConfig) throws {
        if config.kind == .ollama { return } // local, keyless
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment) else {
            throw LLMClientError.missingCredential // fixture builds never touch Keychain
        }
        switch config.authMode {
        case .apiKey:
            guard case .value(let key) = Keychain.read(LLMProviderStore.keychainKey(for: config.id))
            else { throw LLMClientError.missingCredential }
            switch config.kind {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .oauth:
            guard case .value(let json) = Keychain.read(LLMProviderStore.oauthKeychainKey(for: config.id)),
                  let tokens = try? JSONDecoder().decode(LLMOAuthTokens.self, from: Data(json.utf8))
            else { throw LLMClientError.missingCredential }
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            if config.kind == .anthropic {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            }
        }
    }

    private func refreshTokens(vendor: LLMOAuthVendor, providerID: UUID) async throws {
        let key = LLMProviderStore.oauthKeychainKey(for: providerID)
        guard case .value(let json) = Keychain.read(key),
              let tokens = try? JSONDecoder().decode(LLMOAuthTokens.self, from: Data(json.utf8)),
              !tokens.refreshToken.isEmpty
        else { throw LLMClientError.missingCredential }
        let form = LLMOAuth.refreshRequestForm(vendor: vendor, refreshToken: tokens.refreshToken)
        let data = try await Self.postForm(LLMOAuth.constants(for: vendor).tokenURL, form)
        let fresh = try LLMOAuth.parseTokens(from: data, now: Date())
        var merged = fresh
        if merged.refreshToken.isEmpty { merged.refreshToken = tokens.refreshToken }
        let encoded = try JSONEncoder().encode(merged)
        try Keychain.set(String(decoding: encoded, as: UTF8.self), forKey: key)
    }

    /// Model listing for the Settings "Fetch models" button.
    func listModels(config: LLMProviderConfig) async throws -> [String] {
        let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
        let path: String
        switch config.kind {
        case .ollama: path = "\(base)/api/tags"
        case .anthropic: path = "\(base)/v1/models"
        case .openAICompatible:
            path = base.hasSuffix("/v1") ? "\(base)/models" : "\(base)/v1/models"
        }
        guard let url = URL(string: path) else { throw LLMClientError.http(0) }
        try LLMEndpoint.validate(url)
        var request = URLRequest(url: url)
        try applyAuth(to: &request, config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let models = object["models"] as? [[String: Any]] { // Ollama /api/tags
            return models.compactMap { $0["name"] as? String }.sorted()
        }
        if let rows = object["data"] as? [[String: Any]] { // OpenAI + Anthropic
            return rows.compactMap { $0["id"] as? String }.sorted()
        }
        return []
    }

    static func postForm(_ urlString: String, _ form: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw LLMClientError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMClientError.http(status) }
        return data
    }
}

/// Sign in with Claude / ChatGPT: PKCE + loopback redirect, reusing the
/// same listener the Google OAuth flow uses. Stores tokens in the Keychain.
@MainActor
enum LLMOAuthFlow {
    static func signIn(vendor: LLMOAuthVendor, providerID: UUID) async throws {
        guard OAuthConfig.usesKeychain(environment: ProcessInfo.processInfo.environment) else {
            throw LLMClientError.keychainUnavailable
        }
        let pkce = LLMOAuth.PKCE.generate()
        let state = UUID().uuidString
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(expectedState: state)
        let redirectURI = "http://127.0.0.1:\(port)\(LLMOAuth.constants(for: vendor).redirectPath)"
        let url = LLMOAuth.authorizeURL(vendor: vendor, redirectURI: redirectURI,
                                        state: state, challenge: pkce.challenge)
        NSWorkspace.shared.open(url)
        let code = try await codeTask.value
        let form = LLMOAuth.tokenRequestForm(vendor: vendor, code: code,
                                             verifier: pkce.verifier, redirectURI: redirectURI)
        let data = try await LLMClient.postForm(LLMOAuth.constants(for: vendor).tokenURL, form)
        let tokens = try LLMOAuth.parseTokens(from: data, now: Date())
        let encoded = try JSONEncoder().encode(tokens)
        try Keychain.set(String(decoding: encoded, as: UTF8.self),
                         forKey: LLMProviderStore.oauthKeychainKey(for: providerID))
    }
}
```

Adaptation note (concrete, check while implementing): `OAuthService.startLoopbackListener(expectedState:)` at `Sources/MishMail/Auth/OAuth.swift:239` was written for the Google flow. Read it before wiring. If it hard-codes the Google callback path (see `isOAuthCallbackPath` at line 346), extend `isOAuthCallbackPath` to also accept `/callback` — do not fork the listener.

- [ ] **Step 2: Build and run the full suite**

Run: `make test`
Expected: PASS (this task adds no tests; the build must stay green).

- [ ] **Step 3: Commit**

```bash
git add Sources/MishMail/Support/LLMClient.swift Sources/MishMail/Auth/OAuth.swift
git commit -m "feat: streaming LLM client with keychain auth and OAuth sign-in flow

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Settings UI — Providers section and per-task models

**Files:**
- Modify: `Sources/MishMail/UI/SettingsView.swift:1553-1597` (`AISettings`)

**Interfaces:**
- Consumes: `LLMProviderStore`, `LLMProviderConfig`, `LLMClient.shared.listModels`, `LLMOAuthFlow.signIn`, `Keychain.set/.delete`, `LLMTask`, `LLMTaskAssignment`.
- Produces: UI only. Nothing downstream imports it.

- [ ] **Step 1: Extend `AISettings`**

Keep the existing Ollama section, auto-classify toggle, and `MCPSettingsSection` exactly as they are. Insert two new sections between the Ollama section and the auto-classify section:

```swift
struct AISettings: View {
    @State private var url: String = Ollama.baseURL
    @State private var model: String = Ollama.model
    @State private var allowRemote: Bool = Ollama.allowRemoteEndpoint
    @AppStorage(MailStore.autoClassifyKey) private var autoClassify = true
    @State private var providers: [LLMProviderConfig] = LLMProviderStore.load()
    @State private var editingProvider: LLMProviderConfig?
    @State private var addingProvider = false

    // ... existing endpointIsRemote and Ollama/auto-classify/MCP sections stay ...

    // New section 1 — Providers:
    Section {
        ForEach(providers) { provider in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.label)
                    Text("\(provider.kind.rawValue) · \(provider.defaultModel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if provider.id != LLMProviderStore.builtInOllamaID {
                    Button("Edit") { editingProvider = provider }
                        .buttonStyle(.borderless)
                    Button(role: .destructive) { remove(provider) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        Button { addingProvider = true } label: {
            Label("Add provider", systemImage: "plus")
        }
        .buttonStyle(.borderless)
    } header: {
        Text("Model providers")
    } footer: {
        Text("Add your own API keys, or sign in with a Claude or ChatGPT subscription. Keys stay in your Keychain.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // New section 2 — Per-task models:
    Section {
        ForEach(LLMTask.allCases, id: \.self) { task in
            TaskModelPicker(task: task, providers: providers)
        }
    } header: {
        Text("Model per task")
    } footer: {
        Text("Pick which model each feature uses. Keep triage on a small local model; use a bigger model for drafts.")
            .font(.caption).foregroundStyle(.secondary)
    }
    .sheet(isPresented: $addingProvider) {
        ProviderEditSheet(provider: nil) { saved in
            providers = LLMProviderStore.load()
        }
    }
    .sheet(item: $editingProvider) { provider in
        ProviderEditSheet(provider: provider) { _ in
            providers = LLMProviderStore.load()
        }
    }

    private func remove(_ provider: LLMProviderConfig) {
        Keychain.delete(LLMProviderStore.keychainKey(for: provider.id))
        Keychain.delete(LLMProviderStore.oauthKeychainKey(for: provider.id))
        var list = providers
        list.removeAll { $0.id == provider.id }
        LLMProviderStore.save(list)
        providers = LLMProviderStore.load()
    }
}
```

- [ ] **Step 2: Add `TaskModelPicker` and `ProviderEditSheet` (same file, below `AISettings`)**

```swift
private struct TaskModelPicker: View {
    let task: LLMTask
    let providers: [LLMProviderConfig]
    @State private var assignment: LLMTaskAssignment

    init(task: LLMTask, providers: [LLMProviderConfig]) {
        self.task = task
        self.providers = providers
        _assignment = State(initialValue: LLMProviderStore.assignment(for: task))
    }

    private var title: String {
        switch task {
        case .drafts: return "Drafts"
        case .summaries: return "Summaries"
        case .triage: return "Triage"
        case .askMish: return "Ask Mish"
        }
    }

    var body: some View {
        Picker(title, selection: Binding(
            get: { assignment.providerID },
            set: { newID in
                let model = providers.first { $0.id == newID }?.defaultModel ?? ""
                assignment = LLMTaskAssignment(providerID: newID, model: model)
                LLMProviderStore.setAssignment(assignment, for: task)
            })) {
            ForEach(providers) { provider in
                Text("\(provider.label) · \(provider.defaultModel)").tag(provider.id)
            }
        }
    }
}

/// Add/edit one provider. Key goes straight to the Keychain on save; the
/// sheet never re-displays a stored key.
private struct ProviderEditSheet: View {
    let provider: LLMProviderConfig?
    let onSave: (LLMProviderConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Preset {
        let name: String
        let kind: LLMProviderKind
        let baseURL: String
    }
    private static let presets: [Preset] = [
        Preset(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com"),
        Preset(name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1"),
        Preset(name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1"),
        Preset(name: "Grok (xAI)", kind: .openAICompatible, baseURL: "https://api.x.ai/v1"),
        Preset(name: "Groq", kind: .openAICompatible, baseURL: "https://api.groq.com/openai/v1"),
    ]

    @State private var presetIndex = 0
    @State private var label = ""
    @State private var baseURL = ProviderEditSheet.presets[0].baseURL
    @State private var modelID = ""
    @State private var apiKey = ""
    @State private var useOAuth = false
    @State private var models: [String] = []
    @State private var status = ""

    private var kind: LLMProviderKind { Self.presets[presetIndex].kind }
    private var oauthVendor: LLMOAuthVendor? {
        switch Self.presets[presetIndex].name {
        case "Anthropic": return .claude
        case "OpenAI": return .chatGPT
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider == nil ? "Add provider" : "Edit provider").font(.headline)
            Picker("Preset", selection: $presetIndex) {
                ForEach(Self.presets.indices, id: \.self) { i in
                    Text(Self.presets[i].name).tag(i)
                }
            }
            .onChange(of: presetIndex) {
                baseURL = Self.presets[presetIndex].baseURL
                if label.isEmpty { label = Self.presets[presetIndex].name }
            }
            TextField("Label", text: $label)
            TextField("Base URL", text: $baseURL)
            if let vendor = oauthVendor {
                Toggle("Sign in with \(vendor == .claude ? "Claude" : "ChatGPT") instead of a key",
                       isOn: $useOAuth)
            }
            if !useOAuth {
                SecureField("API key", text: $apiKey)
            }
            HStack {
                TextField("Model", text: $modelID)
                Button("Fetch models") { Task { await fetchModels() } }
            }
            if !models.isEmpty {
                Picker("Available", selection: $modelID) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.isEmpty || modelID.isEmpty || (!useOAuth && apiKey.isEmpty && provider == nil))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let existing = provider {
                label = existing.label
                baseURL = existing.baseURL
                modelID = existing.defaultModel
                presetIndex = Self.presets.firstIndex { $0.kind == existing.kind } ?? 0
                if case .oauth = existing.authMode { useOAuth = true }
            }
        }
    }

    private func currentConfig(id: UUID) -> LLMProviderConfig {
        LLMProviderConfig(
            id: id, kind: kind, label: label, baseURL: baseURL, defaultModel: modelID,
            authMode: useOAuth ? .oauth(oauthVendor ?? .claude) : .apiKey)
    }

    private func fetchModels() async {
        status = "Fetching…"
        let id = provider?.id ?? UUID()
        if !useOAuth, !apiKey.isEmpty {
            try? Keychain.set(apiKey, forKey: LLMProviderStore.keychainKey(for: id))
        }
        do {
            models = try await LLMClient.shared.listModels(config: currentConfig(id: id))
            status = models.isEmpty ? "No models returned." : "Found \(models.count) models."
        } catch {
            status = error.localizedDescription
        }
    }

    private func save() async {
        let id = provider?.id ?? UUID()
        let config = currentConfig(id: id)
        do {
            if useOAuth, let vendor = oauthVendor {
                status = "Waiting for browser sign-in…"
                try await LLMOAuthFlow.signIn(vendor: vendor, providerID: id)
            } else if !apiKey.isEmpty {
                try Keychain.set(apiKey, forKey: LLMProviderStore.keychainKey(for: id))
            }
            var list = LLMProviderStore.load().filter { $0.id != id }
            list.append(config)
            LLMProviderStore.save(list)
            onSave(config)
            dismiss()
        } catch {
            status = error.localizedDescription
        }
    }
}
```

- [ ] **Step 3: Build and run the full suite**

Run: `make test`
Expected: PASS (UI-only change; existing suites stay green).

- [ ] **Step 4: Manual verification**

Run: `make run`
- Settings → AI shows "Model providers" with the built-in Ollama row.
- Add provider → Grok preset → paste an xAI key → Fetch models lists `grok-*` → Save.
- Add provider → Anthropic → toggle "Sign in with Claude" → Save opens the browser; on success the sheet closes. If the vendor rejects the flow, the sheet shows the error and API-key mode still works.
- "Model per task" shows Drafts / Summaries / Triage / Ask Mish, all defaulting to Ollama.
- Run `make run MISHMAIL_DEMO=1`: no Keychain prompts appear anywhere in Settings → AI.

- [ ] **Step 5: Commit**

```bash
git add Sources/MishMail/UI/SettingsView.swift
git commit -m "feat: provider list, BYOM key entry, OAuth sign-in, per-task models in Settings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Phase gate — full verification

**Files:** none new.

- [ ] **Step 1: Full suite**

Run: `make test`
Expected: `** TEST SUCCEEDED **` with all new suites (`LLMChatTests`, `LLMWireOpenAITests`, `LLMWireAnthropicTests`, `LLMWireOllamaTests`, `LLMProviderStoreTests`, `LLMOAuthTests`) listed as executed.

- [ ] **Step 2: Live smoke test against one hosted provider**

With a real key configured (Grok or Anthropic), temporarily exercise `LLMClient` from Ask Mish's future entry point — a quick way without UI: add a debug ⌘K command or run the check from Settings via "Fetch models" (already wired). Minimum bar: `listModels` succeeds against one hosted provider and against local Ollama.

- [ ] **Step 3: Update the spec status**

In `docs/plans/2026-08-12-ask-mish-byom-design.md`, under Decisions, append a line: `Phase 1 landed <commit range>.` Commit as `docs:`.

---

## After Phase 1

Phases 2 (Ask Mish panel), 3 (retarget drafts/summaries/triage, inline edits, quick-reply chips), and 4 (follow-up reminders) get their own plans once Phase 1's interfaces are real. Write them with the writing-plans skill, referencing the spec and this plan's Produces blocks.

// kanai-afm-bridge: OpenAI-compatible HTTP bridge to Apple's on-device model.
// Apple frameworks only. Loopback only. No tools are ever passed to the session.
import Foundation
import Network
import FoundationModels

let bridgePort: UInt16 = UInt16(ProcessInfo.processInfo.environment["KANAI_AFM_BRIDGE_PORT"] ?? "") ?? 11437
let bridgeToken: String = ProcessInfo.processInfo.environment["KANAI_AFM_BRIDGE_TOKEN"] ?? ""
let modelId = "apple-foundation"
let maxHeaderBytes = 16 * 1024
let maxBodyBytes = 128 * 1024
let requestReadTimeout: TimeInterval = 10
let generationTimeout: TimeInterval = 100
let maxOpenConnections = 8
let allowedHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

func logLine(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Errors and responses

struct HTTPFail: Error {
    let status: Int
    let type: String
    let message: String
}

func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 411: return "Length Required"
    case 413: return "Payload Too Large"
    case 431: return "Request Header Fields Too Large"
    case 500: return "Internal Server Error"
    case 501: return "Not Implemented"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    case 504: return "Gateway Timeout"
    default: return "Error"
    }
}

func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
}

func httpResponse(status: Int, body: Data, extraHeaders: [String] = []) -> Data {
    var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
    for h in extraHeaders { head += h + "\r\n" }
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Cache-Control: no-store\r\n"
    head += "Connection: close\r\n\r\n"
    return Data(head.utf8) + body
}

func errorResponse(_ f: HTTPFail) -> Data {
    httpResponse(status: f.status, body: jsonData(["error": ["message": f.message, "type": f.type]]))
}

// MARK: - Serialization of model use

actor Serializer {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
let serializer = Serializer()

func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw HTTPFail(status: 504, type: "timeout", message: "The on-device model did not answer within \(Int(seconds)) seconds.")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

// MARK: - JSON extraction (mirrors KanAI's ProposalValidator tolerance, but stricter)

/// First balanced top-level {...} object in `raw`, string-aware.
func extractJSONObject(_ raw: String) -> String? {
    let chars = Array(raw.unicodeScalars)
    guard let start = chars.firstIndex(of: "{") else { return nil }
    var depth = 0, inString = false, escaped = false
    for i in start..<chars.count {
        let c = chars[i]
        if inString {
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString = false }
            continue
        }
        if c == "\"" { inString = true }
        else if c == "{" { depth += 1 }
        else if c == "}" {
            depth -= 1
            if depth == 0 {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: chars[start...i])
                return String(s)
            }
        }
    }
    return nil
}

/// Escapes raw newlines, carriage returns, and tabs that sit inside JSON strings. The model
/// sometimes writes a real line break where JSON needs `\n`, which makes the object invalid.
func escapeControlsInStrings(_ obj: String) -> String {
    var out = String.UnicodeScalarView()
    var inString = false, escaped = false
    for c in obj.unicodeScalars {
        if inString {
            if escaped { escaped = false; out.append(c); continue }
            if c == "\\" { escaped = true; out.append(c); continue }
            if c == "\"" { inString = false; out.append(c); continue }
            switch c {
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            default: out.append(c)
            }
        } else {
            if c == "\"" { inString = true }
            out.append(c)
        }
    }
    return String(out)
}

/// The on-device model ignores the layout rule and writes run-on strings. When a long string
/// value has no line breaks, put each `; ` item on its own `- ` line and each ". Label:" on a new paragraph.
func reflow(_ s: String) -> String {
    s.components(separatedBy: "\n").map(reflowLine).joined(separator: "\n")
}

/// Works one line at a time, so a reply that has a few line breaks of its own still gets its long
/// run-on lines split. A long line with no list shape becomes one sentence per paragraph.
func reflowLine(_ s: String) -> String {
    guard s.count >= 120 else { return s }
    var t = s
    if let re = try? NSRegularExpression(pattern: "([.!?]) ([A-Z][A-Za-z ]{2,30}:)") {
        t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1\n\n$2")
    }
    var paras = t.components(separatedBy: "\n\n")
    for i in paras.indices {
        let items = paras[i].components(separatedBy: "; ")
        // A list needs three items, or two under a "Label:" lead-in. One semicolon in prose stays prose.
        guard items.count >= 2 else { continue }
        var first = items[0], head = ""
        if let r = first.range(of: "^[A-Z][a-z]+( [A-Za-z]+){0,3}: ", options: .regularExpression) {
            head = String(first[r]).trimmingCharacters(in: .whitespaces) + "\n"
            first = String(first[r.upperBound...])
        } else if items.count < 3 { continue }
        paras[i] = head + "- " + ([first] + items.dropFirst()).joined(separator: "\n- ")
    }
    if let re = try? NSRegularExpression(pattern: "([.!?]) (?=[A-Z\\[(#])") {
        for i in paras.indices where paras[i].count >= 200 && !paras[i].contains("\n") {
            let p = paras[i]
            let n = re.numberOfMatches(in: p, range: NSRange(p.startIndex..., in: p))
            if n >= 2 { paras[i] = re.stringByReplacingMatches(in: p, range: NSRange(p.startIndex..., in: p), withTemplate: "$1\n\n") }
        }
    }
    return paras.joined(separator: "\n\n")
}

/// Only the top-level "answer" string is reflowed. Other fields (proposal titles, descriptions) are
/// written into tasks, so they are left exactly as the model wrote them.
func reflowJSONObject(_ obj: String) -> String {
    guard let data = obj.data(using: .utf8),
          var parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let answer = parsed["answer"] as? String else { return obj }
    let flowed = reflow(answer)
    guard flowed != answer else { return obj }
    parsed["answer"] = flowed
    guard let out = try? JSONSerialization.data(withJSONObject: parsed, options: [.withoutEscapingSlashes]),
          let str = String(data: out, encoding: .utf8) else { return obj }
    return str
}

/// A long answer can hit max_tokens before the closing `"}`, which leaves invalid JSON, and the retry
/// is cut off the same way. Recover the top-level "answer" string from such a reply. Proposals are
/// dropped because a half-written one must never be applied.
func salvageTruncatedJSON(_ raw: String) -> String? {
    guard let start = raw.firstIndex(of: "{") else { return nil }
    let text = String(raw[start...])
    guard let open = text.range(of: "^\\{\\s*\"answer\"\\s*:\\s*\"", options: .regularExpression) else { return nil }
    var buf = String.UnicodeScalarView()
    var escaped = false
    for c in text[open.upperBound...].unicodeScalars {
        if escaped { escaped = false; buf.append(c); continue }
        if c == "\\" { escaped = true; buf.append(c); continue }
        if c == "\"" { break }
        buf.append(c)
    }
    var body = String(buf)
    if escaped, body.hasSuffix("\\") { body.removeLast() }
    if let r = body.range(of: "\\\\u[0-9A-Fa-f]{0,3}$", options: .regularExpression) { body.removeSubrange(r) }
    let wrapped = escapeControlsInStrings("[\"" + body + "\"]")
    guard let data = wrapped.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
          let answer = arr.first, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let obj = String(decoding: jsonData(["answer": answer, "proposals": [Any]()]), as: UTF8.self)
    return reflowJSONObject(obj)
}

func validJSONObject(_ raw: String) -> String? {
    guard let extracted = extractJSONObject(raw) else { return nil }
    for obj in [extracted, escapeControlsInStrings(extracted)] {
        if let data = obj.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           parsed is [String: Any] { return reflowJSONObject(obj) }
    }
    return nil
}

// MARK: - Chat completions

func textOf(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let parts = content as? [[String: Any]] {
        return parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
    return ""
}

func handleChat(_ body: Data) async throws -> Data {
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let messages = root["messages"] as? [[String: Any]], !messages.isEmpty else {
        throw HTTPFail(status: 400, type: "invalid_request_error", message: "Body must be a JSON object with a non-empty messages array.")
    }
    if (root["stream"] as? Bool) == true {
        throw HTTPFail(status: 400, type: "invalid_request_error", message: "stream is not supported by kanai-afm-bridge.")
    }

    var systemParts: [String] = []
    var turns: [(role: String, text: String)] = []
    for m in messages {
        let role = (m["role"] as? String) ?? ""
        let text = textOf(m["content"])
        switch role {
        case "system", "developer": systemParts.append(text)
        case "user", "assistant": turns.append((role, text))
        default: throw HTTPFail(status: 400, type: "invalid_request_error", message: "Unsupported message role: \(role)")
        }
    }
    guard let last = turns.last, last.role == "user" else {
        throw HTTPFail(status: 400, type: "invalid_request_error", message: "The last message must have role user.")
    }
    var prompt = last.text
    if turns.count > 1 {
        let history = turns.dropLast().map { ($0.role == "user" ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n")
        prompt = "Conversation so far:\n\(history)\n\nNew user message:\n\(last.text)"
    }

    let format = (root["response_format"] as? [String: Any])?["type"] as? String
    let jsonMode = format == "json_object" || format == "json_schema"
    var instructions = systemParts.joined(separator: "\n\n")
    if jsonMode {
        instructions += "\n\nOutput rule: reply with exactly one JSON object and nothing else. No markdown code fences and no text before or after the object."
        instructions += "\n\nLayout rule (required): inside JSON string values, write line breaks as the two characters \\n. Every project, task, or item goes on its own line starting with \"- \". Put a blank line (\\n\\n) between the summary, the list, and any risks. A reply of two or more items on a single line is wrong. Example of a correct string value: \"Summary sentence.\\n\\n- #89: stalled (appeal denied)\\n- #4: stalled (fee unclear)\\n- #68: partial\\n\\nRisks: #89, #4.\""
    }

    var options = GenerationOptions()
    if let n = (root["max_tokens"] as? Int) ?? (root["max_completion_tokens"] as? Int), n > 0 {
        options.maximumResponseTokens = n
    }
    if let t = root["temperature"] as? Double { options.temperature = min(max(t, 0), 2) }

    let model = SystemLanguageModel.default
    if case .unavailable(let why) = model.availability {
        throw HTTPFail(status: 503, type: "model_unavailable", message: "Apple's on-device model is unavailable: \(why).")
    }

    await serializer.acquire()
    let started = Date()
    let (finalInstructions, finalPrompt, finalOptions) = (instructions, prompt, options)
    do {
        let (content, promptTokens, replyTokens, attempts, salvaged) = try await withTimeout(generationTimeout) {
            try await generate(model: model, instructions: finalInstructions, prompt: finalPrompt, options: finalOptions, jsonMode: jsonMode)
        }
        await serializer.release()
        let replyNote = replyTokens.map { r in finalOptions.maximumResponseTokens.map { r >= $0 ? " reply_tokens=\(r) HIT_MAX_TOKENS" : " reply_tokens=\(r)" } ?? " reply_tokens=\(r)" } ?? ""
        logLine("chat ok json=\(jsonMode) prompt_tokens=\(promptTokens.map(String.init) ?? "unknown")\(replyNote) attempts=\(attempts)\(salvaged ? " SALVAGED" : "") elapsed=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        let reply: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString.prefix(12))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelId,
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
        ]
        // Context gauge: prompt tokens (instructions plus prompt) over the model's window.
        let gauge = promptTokens.map { ["x-kanai-afm-bridge-context: \($0)/\(SystemLanguageModel.default.contextSize)"] } ?? []
        return httpResponse(status: 200, body: jsonData(reply), extraHeaders: gauge)
    } catch {
        await serializer.release()
        let f = mapError(error)
        logLine("chat fail status=\(f.status) type=\(f.type) elapsed=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        throw f
    }
}

func generate(model: SystemLanguageModel, instructions: String, prompt: String, options: GenerationOptions, jsonMode: Bool) async throws -> (String, Int?, Int?, Int, Bool) {
    var tokens: Int? = nil
    if let a = try? await model.tokenCount(for: prompt) {
        var total = a
        if !instructions.isEmpty, let b = try? await model.tokenCount(for: Instructions(instructions)) { total += b }
        tokens = total
    }
    let attempts = jsonMode ? 2 : 1
    for attempt in 0..<attempts {
        var instr = instructions
        if attempt > 0 {
            instr += "\n\nYour previous reply was not a single valid JSON object. Reply again with only the JSON object."
        }
        // No tools, ever.
        let session = LanguageModelSession(model: model, tools: [], instructions: instr.isEmpty ? nil : instr)
        let response = try await session.respond(to: prompt, options: options)
        let replyTokens = try? await model.tokenCount(for: response.content)
        if !jsonMode { return (response.content, tokens, replyTokens, attempt + 1, false) }
        if let ok = validJSONObject(response.content) { return (ok, tokens, replyTokens, attempt + 1, false) }
        // Cut off at max_tokens: a retry would be cut off again, so recover the answer now.
        let hitMax = options.maximumResponseTokens.map { (replyTokens ?? 0) >= $0 } ?? false
        let unbalanced = extractJSONObject(response.content) == nil
        if unbalanced, hitMax || attempt == attempts - 1, let saved = salvageTruncatedJSON(response.content) {
            return (saved, tokens, replyTokens, attempt + 1, true)
        }
    }
    throw HTTPFail(status: 502, type: "invalid_json", message: "The on-device model did not return a valid JSON object after 2 attempts.")
}

func mapError(_ error: Error) -> HTTPFail {
    if let f = error as? HTTPFail { return f }
    if let e = error as? LanguageModelError, case .contextSizeExceeded(let x) = e {
        return HTTPFail(status: 400, type: "context_length_exceeded",
                        message: "Prompt is \(x.tokenCount) tokens but the on-device model context is \(x.contextSize). Lower KanAI's max context tokens.")
    }
    if error is CancellationError {
        return HTTPFail(status: 504, type: "timeout", message: "Generation was cancelled.")
    }
    return HTTPFail(status: 500, type: "generation_failed", message: "On-device model error: \(error.localizedDescription)")
}

func handleModels() -> Data {
    httpResponse(status: 200, body: jsonData(["object": "list", "data": [["id": modelId, "object": "model", "owned_by": "apple"]]]))
}

// MARK: - HTTP parsing and connection handling

struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

let ioQueue = DispatchQueue(label: "kanai-afm-bridge.io")
var openConnections = 0   // touched only on ioQueue

final class Connection {
    let conn: NWConnection
    var buffer = Data()
    var headerDone = false
    var method = "", path = ""
    var headers: [String: String] = [:]
    var contentLength = 0
    var sentContinue = false
    var dispatched = false
    var timer: DispatchWorkItem?

    init(_ c: NWConnection) { conn = c }

    func start() {
        conn.start(queue: ioQueue)
        let t = DispatchWorkItem {
            guard !self.dispatched else { return }
            self.reply(errorResponse(HTTPFail(status: 400, type: "timeout", message: "Request was not received within \(Int(requestReadTimeout)) seconds.")))
        }
        timer = t
        ioQueue.asyncAfter(deadline: .now() + requestReadTimeout, execute: t)
        receive()
    }

    func finish() {
        timer?.cancel()
        conn.cancel()
    }

    func reply(_ data: Data) {
        dispatched = true
        timer?.cancel()
        conn.send(content: data, completion: .contentProcessed { _ in self.finish() })
    }

    func receive() {
        // Strong self on purpose: nothing else owns this object. The cycle breaks when finish() cancels the connection.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            guard !self.dispatched else { return }
            if let data { self.buffer.append(data) }
            if error != nil { self.finish(); return }
            if self.process() { return }
            if isComplete { self.finish(); return }
            self.receive()
        }
    }

    /// Returns true when the request was answered or dispatched.
    func process() -> Bool {
        if !headerDone {
            let sep = Data("\r\n\r\n".utf8)
            guard let r = buffer.range(of: sep) else {
                if buffer.count > maxHeaderBytes {
                    reply(errorResponse(HTTPFail(status: 431, type: "invalid_request_error", message: "Headers too large.")))
                    return true
                }
                return false
            }
            if r.lowerBound - buffer.startIndex > maxHeaderBytes {
                reply(errorResponse(HTTPFail(status: 431, type: "invalid_request_error", message: "Headers too large.")))
                return true
            }
            let headText = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
            let lines = headText.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            guard parts.count >= 2 else {
                reply(errorResponse(HTTPFail(status: 400, type: "invalid_request_error", message: "Malformed request line.")))
                return true
            }
            method = String(parts[0]).uppercased()
            path = String(parts[1]).components(separatedBy: "?")[0]
            for l in lines.dropFirst() {
                guard let i = l.firstIndex(of: ":") else { continue }
                headers[l[l.startIndex..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            buffer = Data(buffer[r.upperBound...])
            headerDone = true
            if headers["transfer-encoding"] != nil {
                reply(errorResponse(HTTPFail(status: 501, type: "invalid_request_error", message: "Chunked request bodies are not supported. Send Content-Length.")))
                return true
            }
            if let cl = headers["content-length"] {
                guard let n = Int(cl), n >= 0 else {
                    reply(errorResponse(HTTPFail(status: 400, type: "invalid_request_error", message: "Bad Content-Length.")))
                    return true
                }
                if n > maxBodyBytes {
                    reply(errorResponse(HTTPFail(status: 413, type: "invalid_request_error", message: "Body larger than \(maxBodyBytes) bytes.")))
                    return true
                }
                contentLength = n
            } else if method == "POST" {
                reply(errorResponse(HTTPFail(status: 411, type: "invalid_request_error", message: "Content-Length required.")))
                return true
            }
        }
        if buffer.count > maxBodyBytes {
            reply(errorResponse(HTTPFail(status: 413, type: "invalid_request_error", message: "Body larger than \(maxBodyBytes) bytes.")))
            return true
        }
        if buffer.count < contentLength {
            if !sentContinue, (headers["expect"] ?? "").lowercased() == "100-continue" {
                sentContinue = true
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            return false
        }
        dispatched = true
        timer?.cancel()
        let req = Request(method: method, path: path, headers: headers, body: Data(buffer.prefix(contentLength)))
        Task { [self] in
            let out = await route(req)
            reply(out)
        }
        return true
    }
}

func route(_ req: Request) async -> Data {
    // Browser and DNS-rebinding guard: only direct clients addressing loopback.
    if req.headers["origin"] != nil {
        return errorResponse(HTTPFail(status: 403, type: "forbidden", message: "Browser cross-origin requests are refused."))
    }
    let host = (req.headers["host"] ?? "").lowercased()
    let hostName = host.hasPrefix("[") ? String(host.prefix(while: { $0 != "]" })) + "]" : host.components(separatedBy: ":")[0]
    if !allowedHosts.contains(hostName) {
        return errorResponse(HTTPFail(status: 403, type: "forbidden", message: "Host header must be 127.0.0.1, localhost, or [::1]."))
    }
    // Optional shared secret. Empty KANAI_AFM_BRIDGE_TOKEN means no authentication.
    if !bridgeToken.isEmpty {
        let given = Array((req.headers["authorization"] ?? "").utf8)
        let want = Array(("Bearer " + bridgeToken).utf8)
        var diff = given.count ^ want.count
        for i in 0..<want.count { diff |= Int(i < given.count ? given[i] : 0) ^ Int(want[i]) }
        if diff != 0 {
            return errorResponse(HTTPFail(status: 401, type: "invalid_api_key", message: "Missing or wrong bearer token."))
        }
    }
    switch (req.method, req.path) {
    case ("GET", "/v1/models"), ("GET", "/models"):
        return handleModels()
    case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
        do { return try await handleChat(req.body) }
        catch { return errorResponse(mapError(error)) }
    case (_, "/v1/models"), (_, "/models"), (_, "/v1/chat/completions"), (_, "/chat/completions"):
        return errorResponse(HTTPFail(status: 405, type: "invalid_request_error", message: "Method not allowed."))
    default:
        return errorResponse(HTTPFail(status: 404, type: "not_found", message: "Unknown path."))
    }
}

// MARK: - Listener

let params = NWParameters.tcp
params.requiredInterfaceType = .loopback
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: bridgePort)!)
params.allowLocalEndpointReuse = true

let listener: NWListener
do { listener = try NWListener(using: params) }
catch { logLine("kanai-afm-bridge: cannot create listener: \(error)"); exit(1) }

listener.stateUpdateHandler = { state in
    switch state {
    case .ready: logLine("kanai-afm-bridge listening on 127.0.0.1:\(bridgePort) model=\(modelId) contextSize=\(SystemLanguageModel.default.contextSize) auth=\(bridgeToken.isEmpty ? "off" : "bearer")")
    case .failed(let e): logLine("kanai-afm-bridge: listener failed: \(e)"); exit(1)
    default: break
    }
}
listener.newConnectionHandler = { c in
    if openConnections >= maxOpenConnections { c.cancel(); return }
    openConnections += 1
    c.stateUpdateHandler = { state in
        switch state {
        case .cancelled, .failed:
            ioQueue.async { openConnections -= 1 }
        default: break
        }
    }
    Connection(c).start()
}
listener.start(queue: ioQueue)

// Load the model now so the first real request does not pay the cold start.
Task {
    if case .available = SystemLanguageModel.default.availability {
        LanguageModelSession(model: .default, tools: [], instructions: nil).prewarm()
        logLine("prewarm requested")
    }
}
dispatchMain()

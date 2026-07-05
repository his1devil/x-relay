#if DEBUG
import Foundation

/// DEBUG-only rich timeline for mock sessions, so the thread UI can be exercised on the
/// simulator (CR_MOCK) with real embed variety — text/markdown, thinking, Read, Bash,
/// Edit diff, Todo, code block — WITHOUT a relay or vibTTY connection. Keyed by the mock
/// session ids created in `SessionStore.loadMock()`.
enum MockTimeline {
    static func timeline(forSessionId id: String) -> [TimelineItem]? {
        // Replay a REAL transcript through the REAL parser (CR_FILE=<path to .jsonl>)
        // — the ground-truth harness for parser-coverage work.
        if id == "cc-file",
           let p = ProcessInfo.processInfo.environment["CR_FILE"],
           let d = try? Data(contentsOf: URL(fileURLWithPath: p)) {
            return TranscriptParser.parse(jsonl: d).timeline.items
        }
        if id == "cc-stress" { return stress() }
        guard id.hasPrefix("cc-") || id.hasPrefix("til-") else { return nil }
        let now = Date()
        func t(_ ago: TimeInterval) -> Date { now.addingTimeInterval(-ago) }

        let readResult = ToolResult(
            text: "export function auth(req) {\n  const t = req.headers.token\n  return t === SECRET\n}",
            isError: false, stdout: nil, stderr: nil, patch: nil)

        let bashResult = ToolResult(
            text: "PASS  src/auth.test.ts\n  ✓ signs a token (4 ms)\n  ✓ rejects a bad token (2 ms)\n\nTests: 12 passed, 12 total",
            isError: false,
            stdout: "PASS  src/auth.test.ts\n  ✓ signs a token (4 ms)\n  ✓ rejects a bad token (2 ms)\n\nTests: 12 passed, 12 total",
            stderr: nil, patch: nil)

        let editPatch = [DiffHunk(
            oldStart: 11, oldLines: 4, newStart: 11, newLines: 6,
            lines: [
                " export function auth(req) {",
                "-  const t = req.headers.token",
                "-  return t === SECRET",
                "+  const t = req.headers.authorization?.split(' ')[1]",
                "+  try { return jwt.verify(t, SECRET) }",
                "+  catch { return null }",
                " }",
            ])]
        let editResult = ToolResult(text: "Applied 1 edit", isError: false, stdout: nil, stderr: nil, patch: editPatch)

        func tool(_ id: String, _ name: String, _ input: JSONValue, _ result: ToolResult?) -> Block {
            .tool(ToolCall(id: id, name: name, input: input, result: result))
        }

        let group1 = AssistantGroup(
            id: "m-a1", time: t(540),
            blocks: [
                .thinking(id: "m-t1", text: "The current `auth` compares a raw header to a shared secret — no expiry, no signing. I'll switch to JWTs: a `signToken` helper plus verification in the middleware."),
                .text(id: "m-x1", text: "I'll refactor `auth.ts` to issue and verify **JWTs**. Plan:\n\n1. Add a `signToken(user)` helper\n2. Verify the bearer token in middleware\n3. Cover both with tests"),
                tool("m-r1", "Read", .object(["file_path": .string("/Users/antai/dev/api/src/auth.ts")]), readResult),
                tool("m-e1", "Edit", .object([
                    "file_path": .string("/Users/antai/dev/api/src/auth.ts"),
                    "old_string": .string("const t = req.headers.token\n  return t === SECRET"),
                    "new_string": .string("const t = req.headers.authorization?.split(' ')[1]\n  try { return jwt.verify(t, SECRET) }\n  catch { return null }"),
                ]), editResult),
                .text(id: "m-x2", text: "New signing helper:\n\n```ts\nexport function signToken(u: User) {\n  return jwt.sign({ sub: u.id }, SECRET, { expiresIn: '1h' })\n}\n```"),
                tool("m-b1", "Bash", .object(["command": .string("npm test -- auth"), "description": .string("Run the auth tests")]), bashResult),
            ],
            model: "claude-sonnet-4-5-20250101", hasThinking: true)

        let group2 = AssistantGroup(
            id: "m-a2", time: t(60),
            blocks: [
                tool("m-td1", "TodoWrite", .object(["todos": .array([
                    .object(["status": .string("completed"), "content": .string("JWT signing + verification")]),
                    .object(["status": .string("in_progress"), "content": .string("Refresh-token rotation")]),
                    .object(["status": .string("pending"), "content": .string("Token revocation list")]),
                ])]), nil),
                .text(id: "m-x3", text: "Tests are green ✅ — 12 passing. I've queued the refresh-token work and started on rotation."),
            ],
            model: "claude-sonnet-4-5-20250101", hasThinking: false)

        return [
            .user(UserMessage(id: "m-u1", text: "Refactor the auth module to use JWTs and add tests.", time: t(600))),
            .assistant(group1),
            .user(UserMessage(id: "m-u2", text: "Nice. Add a todo list for the refresh-token follow-up.", time: t(90))),
            .assistant(group2),
        ]
    }

    /// Deterministic 300-item heavy timeline (big code blocks, diffs, terminal
    /// output, tables) — the scroll/keyboard performance benchmark. Session id
    /// `cc-stress` in `loadMock()`.
    private static func stress() -> [TimelineItem] {
        let now = Date()
        let bigCode = (1 ... 70)
            .map { "let value\($0) = transform(input: \($0), scale: .adaptive, cache: sharedCache)  // keep this line wide enough to scroll" }
            .joined(separator: "\n")
        let bashOut = (1 ... 35).map { "worker[\($0)] ok — processed batch \($0) in \(120 + $0)ms" }.joined(separator: "\n")
        let mdTable = "| endpoint | p50 | p99 |\n|---|---|---|\n"
            + (1 ... 8).map { "| /api/v\($0) | \($0 * 3)ms | \($0 * 11)ms |" }.joined(separator: "\n")

        var items: [TimelineItem] = []
        items.reserveCapacity(300)
        for i in 0 ..< 150 {
            items.append(.user(UserMessage(id: "su\(i)", text: "Stress #\(i): refactor module \(i), explain the tradeoffs, and update the tests.", time: now)))
            let blocks: [Block]
            switch i % 5 {
            case 0:
                blocks = [.text(id: "sa\(i)t", text: "## Module \(i)\nKey points:\n- fast path is allocation-free\n- backpressure via ring buffer\n- **zero** shared locks\n\n\(mdTable)")]
            case 1:
                blocks = [.text(id: "sa\(i)t", text: "Refactored core:\n\n```swift\n\(bigCode)\n```")]
            case 2:
                blocks = [.tool(ToolCall(
                    id: "sa\(i)b", name: "Bash",
                    input: .object(["command": .string("swift test --filter Module\(i)"), "description": .string("Run module \(i) tests")]),
                    result: ToolResult(text: bashOut, isError: false, stdout: bashOut, stderr: nil, patch: nil)))]
            case 3:
                let hunk = DiffHunk(oldStart: 10, oldLines: 6, newStart: 10, newLines: 8, lines: [
                    " func process\(i)() {",
                    "-    legacyPath()",
                    "-    sync()",
                    "+    fastPath()",
                    "+    asyncFlush()",
                    "+    metrics.record()",
                    "+    validate()",
                    " }",
                ])
                blocks = [.tool(ToolCall(
                    id: "sa\(i)e", name: "Edit",
                    input: .object(["file_path": .string("/dev/stress/Module\(i).swift"), "old_string": .string("legacyPath()"), "new_string": .string("fastPath()")]),
                    result: ToolResult(text: "ok", isError: false, stdout: nil, stderr: nil, patch: [hunk])))]
            default:
                blocks = [
                    .thinking(id: "sa\(i)th", text: "Module \(i) has a hot loop; hoisting the allocation and batching the flush should cut p99 latency."),
                    .tool(ToolCall(
                        id: "sa\(i)r", name: "Read",
                        input: .object(["file_path": .string("/dev/stress/Module\(i).swift")]),
                        result: ToolResult(text: bashOut, isError: false, stdout: nil, stderr: nil, patch: nil))),
                    .text(id: "sa\(i)x", text: "Done — module \(i) is now allocation-free on the hot path. Tests green ✅"),
                ]
            }
            items.append(.assistant(AssistantGroup(id: "sa\(i)", time: now, blocks: blocks, model: "claude-sonnet-4-5-20250101", hasThinking: i % 5 == 4)))
        }
        return items
    }
}
#endif

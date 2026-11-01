// Live session state fed by Claude Code hooks (hook.sh), plus the tiny local server they post to.

import AppKit
import Network
import SwiftUI

let serverPort: UInt16 = 47821
let floatDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/float")
let desktopBundleID = "com.anthropic.claudefordesktop"
let floatBundleID = "local.rohan.claudefloat"

// MARK: - Model

enum SessionState {
    case needsYou, working, done
}

struct AskOption: Hashable {
    let label: String
    let detail: String
}

struct AskQuestion: Identifiable {
    let id: Int
    let text: String
    let multi: Bool
    let options: [AskOption]
}

enum RequestKind {
    case permission(tool: String, summary: String, canAlwaysAllow: Bool)
    case question([AskQuestion])
}

struct PendingRequest: Identifiable {
    let id = UUID()
    let kind: RequestKind
}

struct SessionInfo: Identifiable {
    let id: String
    var cwd = ""
    var bundleID = ""
    var state = SessionState.working
    var prompt = ""
    var message = ""
    var updated = Date()
    var seen = true
    var pending: [PendingRequest] = []

    var name: String {
        if cwd.isEmpty { return "Claude" }
        if cwd.contains("/scratch-workspaces/") { return "No folder" }
        return (cwd as NSString).lastPathComponent
    }

    var isFloat: Bool { bundleID == floatBundleID }
    var isDesktop: Bool { bundleID.isEmpty || bundleID == desktopBundleID }
    var appName: String { isFloat ? "Float" : isDesktop ? "Claude" : "Terminal" }
    var appBundle: String { isDesktop ? desktopBundleID : bundleID }
}

/// What you decided about a permission prompt or question.
enum Decision {
    case allow(always: Bool)
    case deny(String)
    case answers([String: String])
    case handBack  // let Claude ask in its own window instead
}

private struct Waiter {
    let sessionID: String
    let respond: (Decision) -> Void
}

final class Store: ObservableObject {
    @Published private(set) var sessions: [String: SessionInfo] = [:]
    /// Replies typed in the float for a busy chat, delivered at its next step.
    @Published private(set) var queued: [String: [String]] = [:]
    var onAllAnswered: () -> Void = {}
    private var waiters: [UUID: Waiter] = [:]

    /// When off, a request is shown in Claude itself if you're already looking at that app.
    var holdAlways: Bool {
        get { UserDefaults.standard.bool(forKey: "holdAlways") }
        set { UserDefaults.standard.set(newValue, forKey: "holdAlways") }
    }

    var needing: [SessionInfo] {
        sessions.values.filter { $0.state == .needsYou }.sorted { $0.updated > $1.updated }
    }

    var needsCount: Int { needing.reduce(0) { $0 + max(1, $1.pending.count) } }
    var anyWorking: Bool { sessions.values.contains { $0.state == .working } }
    var anyUnseenDone: Bool { sessions.values.contains { $0.state == .done && !$0.seen } }

    /// Handles one hook event. Returns the request id when the hook should stay blocked waiting for you.
    func handle(_ j: [String: Any], bundle: String, respond: @escaping (Data) -> Void) -> UUID? {
        guard let sid = j["session_id"] as? String else { respond(Data()); return nil }
        let event = j["hook_event_name"] as? String ?? ""
        if event == "FloatModPoll" {
            // The Float mod in each session checks in here and, when that chat is idle, takes your replies.
            bridged[sid] = Date()
            let texts = (j["idle"] as? Bool == true) ? takeAll(sid) : []
            respond((try? JSONSerialization.data(withJSONObject: ["texts": texts])) ?? Data())
            return nil
        }
        if event == "SessionEnd" {
            end(sid)
            respond(Data())
            return nil
        }
        var s = sessions[sid] ?? SessionInfo(id: sid)
        if let cwd = j["cwd"] as? String { s.cwd = cwd }
        if !bundle.isEmpty { s.bundleID = bundle }
        s.updated = Date()

        var output: [String: Any]?
        var waiting: UUID?
        switch event {
        case "UserPromptSubmit":
            s.state = .working
            s.prompt = oneLine(j["prompt"] as? String ?? "")
            s.message = ""
            s.seen = true
            output = takeQueued(sid).map(Self.context(event))
        case "PostToolUse":
            if s.pending.isEmpty { s.state = .working; s.message = "" }
            output = takeQueued(sid).map(Self.context(event))
        case "Notification":
            let type = j["notification_type"] as? String ?? ""
            if (type == "permission_prompt" || type == "elicitation_dialog") && s.pending.isEmpty {
                s.state = .needsYou
                s.message = j["message"] as? String ?? "Waiting for you in \(s.appName)"
            }
        case "Stop":
            if let text = takeQueued(sid) {
                output = ["decision": "block", "reason": "The user sent this message from Claude Float. Treat it as their next message:\n\n\(text)"]
                s.state = .working
            } else {
                s.state = .done
                s.message = oneLine(j["last_assistant_message"] as? String ?? "")
                s.seen = false
            }
        case "PermissionRequest", "PreToolUse":
            let tool = j["tool_name"] as? String ?? "a tool"
            let input = j["tool_input"] as? [String: Any] ?? [:]
            let suggestions = j["permission_suggestions"] as? [Any] ?? []
            guard let request = makeRequest(tool: tool, input: input, suggestions: suggestions,
                                            permission: event == "PermissionRequest") else { break }
            s.state = .needsYou
            let lookingAtIt = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == s.appBundle
            if !s.isFloat && !holdAlways && lookingAtIt {
                s.message = "Waiting for you in \(s.appName)"
            } else {
                s.message = ""
                s.pending.append(request)
                waiters[request.id] = Waiter(sessionID: sid) { decision in
                    respond(Self.hookOutput(decision, event: event, input: input, suggestions: suggestions))
                }
                waiting = request.id
            }
        default:
            break
        }
        sessions[sid] = s
        if waiting == nil {
            respond(output.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data())
        }
        return waiting
    }

    /// A permission prompt or question from a chat the float runs itself.
    func addControlRequest(sessionID sid: String, tool: String, input: [String: Any], suggestions: [Any],
                           respond: @escaping (Decision) -> Void) -> UUID? {
        guard let request = makeRequest(tool: tool, input: input, suggestions: suggestions, permission: true) else { return nil }
        var s = sessions[sid] ?? SessionInfo(id: sid)
        s.bundleID = floatBundleID
        s.state = .needsYou
        s.message = ""
        s.updated = Date()
        s.pending.append(request)
        sessions[sid] = s
        waiters[request.id] = Waiter(sessionID: sid, respond: respond)
        return request.id
    }

    private func makeRequest(tool: String, input: [String: Any], suggestions: [Any], permission: Bool) -> PendingRequest? {
        if tool == "AskUserQuestion", let qs = input["questions"] as? [[String: Any]] {
            let questions = qs.enumerated().map { i, q in
                AskQuestion(
                    id: i,
                    text: q["question"] as? String ?? "",
                    multi: q["multiSelect"] as? Bool ?? false,
                    options: (q["options"] as? [[String: Any]] ?? []).map {
                        AskOption(label: $0["label"] as? String ?? "", detail: $0["description"] as? String ?? "")
                    })
            }
            return PendingRequest(kind: .question(questions))
        }
        guard permission else { return nil }
        return PendingRequest(kind: .permission(tool: tool, summary: summarize(tool, input), canAlwaysAllow: !suggestions.isEmpty))
    }

    private static func context(_ event: String) -> (String) -> [String: Any] {
        { text in
            ["hookSpecificOutput": ["hookEventName": event,
                                    "additionalContext": "The user sent this message from Claude Float while you were working. Treat it as their message:\n\n\(text)"]]
        }
    }

    private static func hookOutput(_ d: Decision, event: String, input: [String: Any], suggestions: [Any]) -> Data {
        let out: [String: Any]?
        switch d {
        case .handBack:
            out = nil
        case .allow(let always):
            var decision: [String: Any] = ["behavior": "allow"]
            if always && !suggestions.isEmpty { decision["updatedPermissions"] = suggestions }
            out = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        case .deny(let message):
            out = event == "PreToolUse"
                ? ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": message]]
                : ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "deny", "message": message]]]
        case .answers(let answers):
            var updated = input
            updated["answers"] = answers
            out = event == "PreToolUse"
                ? ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]]
                : ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow", "updatedInput": updated]]]
        }
        return out.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
    }

    // MARK: Answers

    func allow(_ id: UUID, always: Bool) { finish(id, .allow(always: always)) }

    func deny(_ id: UUID, note: String) {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(id, .deny(note.isEmpty ? "The user said no." : "The user said no and added: \(note)"))
    }

    func answer(_ id: UUID, _ answers: [String: String]) { finish(id, .answers(answers)) }

    func handBack(_ id: UUID) { finish(id, .handBack) }

    func handBackAll() { waiters.keys.forEach(handBack) }

    /// The request went away without you (stopped, or answered in Claude).
    func dropped(_ id: UUID) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        removePending(id, from: w.sessionID, next: .working, message: "")
    }

    func dropAll(_ sid: String) {
        for (id, w) in waiters where w.sessionID == sid { dropped(id) }
        if sessions[sid]?.state == .needsYou { sessions[sid]?.state = .done }
    }

    private func finish(_ id: UUID, _ decision: Decision) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        w.respond(decision)
        if case .handBack = decision {
            removePending(id, from: w.sessionID, next: .needsYou, message: "Waiting for you in \(sessions[w.sessionID]?.appName ?? "Claude")")
        } else {
            removePending(id, from: w.sessionID, next: .working, message: "")
        }
        if waiters.isEmpty { onAllAnswered() }
    }

    private func removePending(_ id: UUID, from sid: String, next: SessionState, message: String) {
        guard var s = sessions[sid] else { return }
        s.pending.removeAll { $0.id == id }
        if s.pending.isEmpty { s.state = next; s.message = message }
        sessions[sid] = s
    }

    // MARK: Queued replies

    func queue(_ text: String, for sid: String) { queued[sid, default: []].append(text) }

    func unqueue(_ sid: String, at index: Int) {
        guard queued[sid]?.indices.contains(index) == true else { return }
        queued[sid]?.remove(at: index)
        if queued[sid]?.isEmpty == true { queued[sid] = nil }
    }

    /// Sessions whose Float mod checked in, and when.
    private var bridged: [String: Date] = [:]

    func isBridged(_ sid: String) -> Bool { (bridged[sid].map { Date().timeIntervalSince($0) < 6 }) ?? false }

    private func takeAll(_ sid: String) -> [String] {
        guard let q = queued[sid], !q.isEmpty else { return [] }
        queued[sid] = nil
        return q
    }

    private func takeQueued(_ sid: String) -> String? {
        guard let q = queued[sid], !q.isEmpty else { return nil }
        queued[sid] = nil
        return q.joined(separator: "\n\n")
    }

    // MARK: Sessions

    func appActivated(_ bundle: String?) {
        guard let bundle, !holdAlways else { return }
        for (id, w) in waiters {
            guard let s = sessions[w.sessionID], !s.isFloat else { continue }
            if bundle == s.appBundle { handBack(id) }
        }
    }

    func markSeen() {
        for id in sessions.keys where sessions[id]?.seen == false { sessions[id]?.seen = true }
    }

    private func end(_ sid: String) {
        for (id, w) in waiters where w.sessionID == sid { handBack(id) }
        sessions[sid] = nil
    }

    /// Drops sessions that went quiet, e.g. a terminal that was closed without ending Claude.
    func prune() {
        let now = Date()
        for s in sessions.values {
            let idle = now.timeIntervalSince(s.updated)
            if s.state == .done && idle > 3 * 3600 { sessions[s.id] = nil }
            if s.state == .working && idle > 3600 { sessions[s.id]?.state = .done }
        }
    }
}

func oneLine(_ text: String, max: Int = 160) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return flat.count > max ? String(flat.prefix(max)) + "…" : flat
}

/// The one field that says what a tool call does, e.g. the command or file path.
func keyField(_ input: [String: Any]) -> String? {
    for key in ["command", "file_path", "notebook_path", "url", "query", "pattern", "path", "description", "prompt"] {
        if let value = input[key] as? String, !value.isEmpty { return value }
    }
    return nil
}

func summarize(_ tool: String, _ input: [String: Any]) -> String {
    if let value = keyField(input) { return value }
    guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "" }
    return text.count > 400 ? String(text.prefix(400)) + "…" : text
}

// MARK: - Hook server

/// A tiny HTTP server on 127.0.0.1. Hooks for prompts and questions keep their connection open until you answer.
final class HookServer {
    private let listener: NWListener
    private let token: String
    private let store: Store

    init(token: String, store: Store) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: serverPort)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.token = token
        self.store = store
    }

    func start(onFailure: @escaping (Error) -> Void) {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { onFailure(error) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.read(connection, buffer: Data())
        }
        listener.start(queue: .main)
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = Self.parse(buffer) {
                self.route(c, headers: parsed.0, body: parsed.1)
            } else if done || error != nil || buffer.count > 4_000_000 {
                c.cancel()
            } else {
                self.read(c, buffer: buffer)
            }
        }
    }

    private static func parse(_ buffer: Data) -> ([String: String], Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = buffer[end.upperBound...]
        guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }
        return (headers, Data(body))
    }

    private func route(_ c: NWConnection, headers: [String: String], body: Data) {
        var sent = false
        let respond: (Int, Data) -> Void = { status, data in
            guard !sent else { return }
            sent = true
            let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Forbidden")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
        }
        guard headers["x-float-token"] == token,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(403, Data())
            return
        }
        guard let waiting = store.handle(json, bundle: headers["x-bundle"] ?? "", respond: { respond(200, $0) }) else { return }
        // If the hook process goes away (stopped or answered in Claude), forget the request.
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, done, error in
            if done || error != nil { self?.store.dropped(waiting) }
        }
    }
}

// Today's chats: read from Claude's transcripts, joined with the running-session registry,
// plus chats the float runs itself with `claude -p` in stream-json mode.

import AppKit
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser

struct ChatLine: Identifiable {
    enum Kind { case user, assistant, tool }
    let id: Int
    let kind: Kind
    let text: String
}

struct ChatMeta {
    let sessionID: String
    var cwd = ""
    var entrypoint = ""
    var customTitle: String?
    var aiTitle: String?
    var firstPrompt: String?
    var lastText = ""
    var modified = Date.distantPast
    var lines: [ChatLine] = []

    var title: String { customTitle ?? aiTitle ?? firstPrompt ?? "New chat" }
}

func projectName(_ cwd: String) -> String {
    if cwd.isEmpty { return "" }
    if cwd.contains("/scratch-workspaces/") { return "No folder" }
    return (cwd as NSString).lastPathComponent
}

// MARK: - Transcripts

/// Reads transcripts incrementally: each refresh only parses what was appended since the last one.
/// Only touched from its own queue.
final class TranscriptIndex {
    private final class FileState {
        var offset: UInt64 = 0
        var leftover = Data()
        var nextID = 0
        var meta: ChatMeta
        init(_ id: String) { meta = ChatMeta(sessionID: id) }
    }

    private var files: [String: FileState] = [:]
    private let root = home.appendingPathComponent(".claude/projects")
    private static let maxLines = 400
    /// Big entries that never hold chat text; skipping them avoids parsing megabytes of JSON.
    private static let skip = ["\"type\":\"api-request", "\"type\":\"attachment\"", "\"type\":\"file-history-snapshot\"",
                               "\"type\":\"progress\""].map { Data($0.utf8) }

    func scan(since: Date) -> [ChatMeta] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var seen = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= since else { continue }
                let path = url.path
                seen.insert(path)
                let state = files[path] ?? FileState(url.deletingPathExtension().lastPathComponent)
                files[path] = state
                state.meta.modified = modified
                let size = UInt64(values.fileSize ?? 0)
                if size < state.offset {
                    let fresh = FileState(state.meta.sessionID)
                    files[path] = fresh
                    read(fresh, path)
                } else if size > state.offset {
                    read(state, path)
                }
            }
        }
        files = files.filter { seen.contains($0.key) }
        return files.values.map(\.meta).filter { !$0.lines.isEmpty }
    }

    private func read(_ s: FileState, _ path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: s.offset)
        let data = handle.readDataToEndOfFile()
        s.offset += UInt64(data.count)
        let buffer = s.leftover + data
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            parse(buffer[start..<newline], into: s)
            start = buffer.index(after: newline)
        }
        s.leftover = Data(buffer[start...])
        if s.meta.lines.count > Self.maxLines { s.meta.lines.removeFirst(s.meta.lines.count - Self.maxLines) }
    }

    private func parse(_ line: Data, into s: FileState) {
        if Self.skip.contains(where: { line.range(of: $0) != nil }) { return }
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = o["type"] as? String else { return }
        switch type {
        case "custom-title":
            s.meta.customTitle = o["customTitle"] as? String
        case "ai-title":
            s.meta.aiTitle = o["aiTitle"] as? String
        case "user", "assistant":
            if o["isSidechain"] as? Bool == true || o["isMeta"] as? Bool == true { return }
            if let cwd = o["cwd"] as? String { s.meta.cwd = cwd }
            if s.meta.entrypoint.isEmpty, let entry = o["entrypoint"] as? String { s.meta.entrypoint = entry }
            let content = (o["message"] as? [String: Any])?["content"]
            let blocks = (content as? String).map { [["type": "text", "text": $0]] } ?? (content as? [[String: Any]] ?? [])
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    let raw = b["text"] as? String ?? ""
                    if type == "user" {
                        guard let text = cleanUserText(raw) else { continue }
                        add(.user, text, to: s)
                        if s.meta.firstPrompt == nil { s.meta.firstPrompt = oneLine(text, max: 80) }
                    } else {
                        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        add(.assistant, text, to: s)
                        s.meta.lastText = oneLine(text)
                    }
                case "tool_use" where type == "assistant":
                    var name = b["name"] as? String ?? "Tool"
                    if name.hasPrefix("mcp__") { name = name.components(separatedBy: "__").last ?? name }
                    let detail = keyField(b["input"] as? [String: Any] ?? [:]).map { " · " + oneLine($0, max: 120) } ?? ""
                    add(.tool, name + detail, to: s)
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private func add(_ kind: ChatLine.Kind, _ text: String, to s: FileState) {
        s.meta.lines.append(ChatLine(id: s.nextID, kind: kind, text: text))
        s.nextID += 1
    }
}

/// Drops the bits of a user turn that Claude adds itself (reminders, slash-command plumbing).
func cleanUserText(_ raw: String) -> String? {
    let text = raw.replacingOccurrences(of: "<system-reminder>[\\s\\S]*?</system-reminder>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let noise = ["<command-", "<local-command", "Caveat:", "[Request interrupted", "<task-notification", "<side-sessions",
                 "<ci-monitor", "<user-prompt-submit-hook"]
    if text.isEmpty || noise.contains(where: text.hasPrefix) { return nil }
    return text
}

// MARK: - Running sessions

struct LiveSession {
    let sessionID: String
    let busy: Bool
    let entrypoint: String
    let hostSessionID: String?
}

/// Claude writes one file per running session to ~/.claude/sessions.
func readRegistry() -> [String: LiveSession] {
    let dir = home.appendingPathComponent(".claude/sessions")
    var live: [String: LiveSession] = [:]
    for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = o["pid"] as? Int32 ?? (o["pid"] as? Int).map(Int32.init),
              let sid = o["sessionId"] as? String,
              kill(pid, 0) == 0 || errno == EPERM else { continue }
        live[sid] = LiveSession(sessionID: sid, busy: o["status"] as? String == "busy",
                                entrypoint: o["entrypoint"] as? String ?? "", hostSessionID: o["hostSessionId"] as? String)
    }
    return live
}

// MARK: - Chats run by the float

/// One `claude -p` process speaking stream-json, kept open so you can keep replying.
final class FloatChat {
    let key = UUID().uuidString
    let cwd: String
    let resumedFrom: String?
    let firstPrompt: String
    var sessionID: String?
    var busy = true
    var alive = true
    var lastError = ""
    var onChange: () -> Void = {}

    private weak var store: Store?
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private var buffer = Data()
    private var controlRequests: [String: UUID] = [:]

    init(cwd: String, prompt: String, resume: String?, store: Store) {
        self.cwd = cwd
        self.firstPrompt = prompt
        self.resumedFrom = resume
        self.store = store
        sessionID = resume
    }

    func start() {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-prompt-tool", "stdio"]
        if let resumedFrom { args += ["--resume", resumedFrom] }
        process.executableURL = URL(fileURLWithPath: claudePath())
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        env["PATH"] = loginPath
        env["__CFBundleIdentifier"] = floatBundleID
        env["CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL"] = "true"
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
            DispatchQueue.main.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { guard let self else { return }; self.lastError = String((self.lastError + text).suffix(600)) }
        }
        process.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.ended() } }
        do {
            try process.run()
            send(firstPrompt)
        } catch {
            lastError = "Couldn't start Claude: \(error.localizedDescription)"
            ended()
        }
    }

    func send(_ text: String) {
        write(["type": "user", "message": ["role": "user", "content": text]])
        busy = true
        onChange()
    }

    func stop() { if process.isRunning { process.terminate() } }

    private func write(_ object: [String: Any]) {
        guard alive, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(o)
        }
        onChange()
    }

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init", let sid = o["session_id"] as? String { sessionID = sid }
        case "result":
            busy = false
        case "control_request":
            guard let rid = o["request_id"] as? String, let request = o["request"] as? [String: Any] else { return }
            guard request["subtype"] as? String == "can_use_tool" else {
                write(["type": "control_response", "response": ["subtype": "error", "request_id": rid, "error": "Not supported by Claude Float"]])
                return
            }
            let input = request["input"] as? [String: Any] ?? [:]
            let suggestions = request["permission_suggestions"] as? [Any] ?? []
            controlRequests[rid] = store?.addControlRequest(
                sessionID: sessionID ?? key, tool: request["tool_name"] as? String ?? "a tool", input: input, suggestions: suggestions
            ) { [weak self] decision in self?.reply(rid, decision, input: input, suggestions: suggestions) }
        case "control_cancel_request":
            if let rid = o["request_id"] as? String, let id = controlRequests.removeValue(forKey: rid) { store?.dropped(id) }
        default:
            break
        }
    }

    private func reply(_ rid: String, _ decision: Decision, input: [String: Any], suggestions: [Any]) {
        controlRequests[rid] = nil
        var r: [String: Any]
        switch decision {
        case .allow(let always):
            r = ["behavior": "allow", "updatedInput": input]
            if always { r["updatedPermissions"] = suggestions }
        case .answers(let answers):
            var updated = input
            updated["answers"] = answers
            r = ["behavior": "allow", "updatedInput": updated]
        case .deny(let message):
            r = ["behavior": "deny", "message": message]
        case .handBack:
            r = ["behavior": "deny", "message": "The user dismissed this."]
        }
        write(["type": "control_response", "response": ["subtype": "success", "request_id": rid, "response": r]])
    }

    private func ended() {
        guard alive else { return }
        alive = false
        busy = false
        if let sessionID { store?.dropAll(sessionID) }
        onChange()
    }
}

func claudePath() -> String {
    let candidates = [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0).path }
        + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/claude"
}

/// Apps opened from Finder get a bare PATH; chats need the one your shell uses.
let loginPath: String = {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "printf %s \"$PATH\""]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    if (try? p.run()) != nil {
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if !path.isEmpty { return path }
    }
    return home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}()

// MARK: - The list the panel shows

enum ChatStatus {
    case needsYou, working, idle, ended

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working…"
        case .idle: return "Waiting for you"
        case .ended: return "Ended"
        }
    }
}

/// How a reply typed in the float reaches the chat.
enum ReplyMode {
    case direct(FloatChat)  // the float runs it
    case queue              // busy elsewhere: delivered by hooks at its next step
    case bridge             // idle, with the Float mod loaded: the mod submits it as your message
    case handOff            // idle in Claude or a terminal: copied, then that chat is opened
    case resume             // ended: continued here in the float
}

struct ChatRow: Identifiable {
    let id: String
    let title: String
    let project: String
    let origin: String
    let modified: Date
    let lastText: String
}

final class ChatsModel: ObservableObject {
    @Published private(set) var metas: [String: ChatMeta] = [:]
    @Published private(set) var live: [String: LiveSession] = [:]
    @Published private(set) var floats: [FloatChat] = []
    @Published var notice: String?
    @Published private(set) var loaded = false
    var chooseFolder: () -> String? = { nil }

    let store: Store
    private let index = TranscriptIndex()
    private let queue = DispatchQueue(label: "float.transcripts", qos: .userInitiated)
    private var scanning = false
    private var signature = ""
    private var timer: Timer?

    init(store: Store) { self.store = store }

    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let since = Calendar.current.startOfDay(for: Date())
        queue.async { [weak self] in
            guard let self else { return }
            let metas = self.index.scan(since: since)
            let live = readRegistry()
            let signature = metas.map { "\($0.sessionID):\($0.lines.count):\($0.title)" }.sorted().joined(separator: ",")
                + live.values.map { "\($0.sessionID):\($0.busy)" }.sorted().joined(separator: ",")
            DispatchQueue.main.async {
                self.scanning = false
                self.loaded = true
                guard signature != self.signature else { return }
                self.signature = signature
                self.metas = Dictionary(metas.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
                self.live = live
            }
        }
    }

    // MARK: Rows

    var rows: [ChatRow] {
        var rows = metas.values.compactMap { m -> ChatRow? in
            let origin = self.origin(m.sessionID)
            if origin == nil { return nil }
            return ChatRow(id: m.sessionID, title: m.title,
                           project: projectName(m.cwd), origin: origin!, modified: m.modified, lastText: m.lastText)
        }
        for f in floats where f.alive && (f.sessionID.map { metas[$0] == nil } ?? true) {
            rows.append(ChatRow(id: f.key, title: oneLine(f.firstPrompt, max: 80), project: projectName(f.cwd), origin: "Float",
                                modified: Date(), lastText: ""))
        }
        return rows.sorted { $0.modified > $1.modified }
    }

    /// App, Terminal or Float; nil for background runs by other tools, which aren't shown.
    func origin(_ id: String) -> String? {
        if float(for: id) != nil || floatSessionIDs.contains(id) { return "Float" }
        let entry = live[id]?.entrypoint ?? metas[id]?.entrypoint ?? ""
        if entry == "claude-desktop" { return "App" }
        if entry == "cli" { return "Terminal" }
        return nil
    }

    func float(for id: String) -> FloatChat? {
        floats.last { $0.key == id || $0.sessionID == id || $0.resumedFrom == id }
    }

    /// A chat route may start as a float's key before Claude reports the real session id.
    func resolve(_ key: String) -> String { float(for: key)?.sessionID ?? key }

    func title(_ id: String) -> String {
        if let m = metas[id] { return m.title }
        if let f = float(for: id) { return oneLine(f.firstPrompt, max: 80) }
        return projectName(store.sessions[id]?.cwd ?? "")
    }

    func project(_ id: String) -> String { projectName(metas[id]?.cwd ?? float(for: id)?.cwd ?? store.sessions[id]?.cwd ?? "") }

    func lines(_ id: String) -> [ChatLine] {
        metas[id]?.lines ?? float(for: id)?.resumedFrom.flatMap { metas[$0]?.lines } ?? []
    }

    func status(_ id: String) -> ChatStatus {
        if store.sessions[id]?.state == .needsYou { return .needsYou }
        if let f = float(for: id), f.alive { return f.busy ? .working : .idle }
        if let l = live[id] { return l.busy ? .working : .idle }
        return .ended
    }

    func replyMode(_ id: String) -> ReplyMode {
        if let f = float(for: id), f.alive { return .direct(f) }
        if let l = live[id] { return l.busy ? .queue : store.isBridged(id) ? .bridge : .handOff }
        return .resume
    }

    // MARK: Actions

    /// Returns the chat to show afterwards (it changes when an ended chat is continued here).
    @discardableResult
    func send(_ text: String, to id: String) -> String {
        switch replyMode(id) {
        case .direct(let f):
            f.send(text)
        case .queue, .bridge:
            store.queue(text, for: id)
        case .handOff:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            openInApp(id)
            notice = "Your reply is copied. Paste it into the chat that just opened."
        case .resume:
            return startFloat(cwd: metas[id]?.cwd ?? home.path, prompt: text, resume: id).key
        }
        return id
    }

    /// Starts a chat. Returns its key when it runs in the float, or nil when it was handed to the Claude app.
    func startNew(cwd: String, prompt: String, inApp: Bool) -> String? {
        rememberFolder(cwd)
        if inApp {
            var link = URLComponents(string: "claude://code/new")!
            link.queryItems = [URLQueryItem(name: "q", value: prompt), URLQueryItem(name: "folder", value: cwd)]
            if let url = link.url { NSWorkspace.shared.open(url) }
            return nil
        }
        return startFloat(cwd: cwd, prompt: prompt, resume: nil).key
    }

    private func startFloat(cwd: String, prompt: String, resume: String?) -> FloatChat {
        let chat = FloatChat(cwd: cwd, prompt: prompt, resume: resume, store: store)
        chat.onChange = { [weak self] in
            self?.objectWillChange.send()
            guard let self, let sid = chat.sessionID else { return }
            if !self.floatSessionIDs.contains(sid) {
                self.floatSessionIDs = Array(([sid] + self.floatSessionIDs).prefix(200))
            }
            self.refresh()
        }
        floats.append(chat)
        chat.start()
        return chat
    }

    /// Chats the float started, so they still show as Float after a restart.
    private var floatSessionIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "floatSessions") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "floatSessions") }
    }

    func canOpenInApp(_ id: String) -> Bool { !(float(for: id)?.alive ?? false) }

    func openInApp(_ id: String) {
        if let l = live[id], l.entrypoint == "claude-desktop", let host = l.hostSessionID,
           let url = URL(string: "claude://code/continue?session=\(host)") {
            NSWorkspace.shared.open(url)
        } else if live[id]?.entrypoint == "cli" {
            activate(store.sessions[id]?.bundleID ?? "com.apple.Terminal")
        } else if metas[id]?.entrypoint == "claude-desktop" || metas[id] == nil {
            activate(desktopBundleID)
        } else if let url = URL(string: "claude://resume?session=\(id)") {
            NSWorkspace.shared.open(url)  // brings a terminal or float chat into the Claude app
        }
    }

    func activate(_ bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func stopAll() { floats.forEach { $0.stop() } }

    // MARK: Folders

    var recentFolders: [String] {
        let saved = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        let today = metas.values.sorted { $0.modified > $1.modified }.map(\.cwd)
        var seen = Set<String>()
        return (saved + today + [home.path]).filter {
            !$0.isEmpty && !$0.contains("/scratch-workspaces/") && !$0.hasPrefix("/private/") && seen.insert($0).inserted
        }.prefix(10).map { $0 }
    }

    private func rememberFolder(_ path: String) {
        var saved = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        saved.removeAll { $0 == path }
        saved.insert(path, at: 0)
        UserDefaults.standard.set(Array(saved.prefix(8)), forKey: "recentFolders")
    }
}

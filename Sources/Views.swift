// The panel: today's chats, one chat at a time, and a form to start a new one.

import AppKit
import SwiftUI

enum Route: Equatable {
    case home
    case chat(String)
    case newChat
}

final class Nav: ObservableObject {
    @Published var route = Route.home
}

extension ChatStatus {
    var color: Color {
        switch self {
        case .needsYou: return .orange
        case .working: return .blue
        case .idle: return .green
        case .ended: return .gray
        }
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelRoot: View {
    @ObservedObject var store: Store
    @ObservedObject var chats: ChatsModel
    @ObservedObject var nav: Nav
    let onHeight: (CGFloat) -> Void

    var body: some View {
        switch nav.route {
        case .home:
            ScrollView {
                HomeView(store: store, chats: chats, nav: nav)
                    .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .onPreferenceChange(HeightKey.self) { onHeight($0) }
        case .chat(let key):
            ChatView(key: key, store: store, chats: chats, nav: nav).id(key)
        case .newChat:
            NewChatView(chats: chats, nav: nav)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var store: Store
    @ObservedObject var chats: ChatsModel
    @ObservedObject var nav: Nav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { nav.route = .newChat } label: { Label("New chat", systemImage: "plus") }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 8)

            let needing = store.needing
            if !needing.isEmpty {
                SectionTitle("Needs you")
                ForEach(needing) { s in
                    NeedsYouRow(session: s, title: chats.title(s.id), store: store, chats: chats) { nav.route = .chat(s.id) }
                    Divider().opacity(0.6)
                }
            }

            SectionTitle("Today")
            let rows = chats.rows.prefix(40)
            if rows.isEmpty {
                Text(chats.loaded ? "No chats yet today." : "Loading…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
            ForEach(Array(rows)) { row in
                ChatRowView(row: row, status: chats.status(row.id)) { nav.route = .chat(row.id) }
            }
            Spacer().frame(height: 6)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
    }
}

struct ChatRowView: View {
    let row: ChatRow
    let status: ChatStatus
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(status.color).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.modified, style: .time).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text([row.project, row.origin, status.label].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if !row.lastText.isEmpty {
                        Text(row.lastText).font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.8)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A chat that's blocked on you, with its prompts answerable right here.
struct NeedsYouRow: View {
    let session: SessionInfo
    let title: String
    let store: Store
    let chats: ChatsModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(title.isEmpty ? session.name : title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(session.appName)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if session.pending.isEmpty && !session.message.isEmpty {
                HStack {
                    Text(session.message).font(.system(size: 12)).lineLimit(3)
                    Spacer()
                    Button("Open") { chats.openInApp(session.id) }.controlSize(.small)
                }
            }
            PendingList(session: session, store: store, chats: chats)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct PendingList: View {
    let session: SessionInfo
    let store: Store
    let chats: ChatsModel

    var body: some View {
        ForEach(session.pending) { p in
            switch p.kind {
            case let .permission(tool, summary, canAlways):
                PermissionCard(id: p.id, tool: tool, summary: summary, canAlways: canAlways, store: store, chats: chats, session: session)
            case let .question(questions):
                QuestionCard(id: p.id, questions: questions, store: store, chats: chats, session: session)
            }
        }
    }
}

// MARK: - Prompts

struct PermissionCard: View {
    let id: UUID
    let tool: String
    let summary: String
    let canAlways: Bool
    let store: Store
    let chats: ChatsModel
    let session: SessionInfo
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wants to use \(tool)").font(.system(size: 12, weight: .medium))
            if !summary.isEmpty {
                Text(summary).font(.system(size: 11, design: .monospaced)).lineLimit(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            HStack(spacing: 6) {
                Button("Allow") { store.allow(id, always: false) }.buttonStyle(.borderedProminent)
                if canAlways { Button("Always allow") { store.allow(id, always: true) } }
                Button("Deny") { store.deny(id, note: note) }
                Spacer()
                HandBackButton(id: id, store: store, chats: chats, session: session)
            }
            .controlSize(.small)
            TextField("Or tell Claude what to do instead…", text: $note)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .onSubmit { if !note.isEmpty { store.deny(id, note: note) } }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.08)))
    }
}

struct QuestionCard: View {
    let id: UUID
    let questions: [AskQuestion]
    let store: Store
    let chats: ChatsModel
    let session: SessionInfo
    @State private var picked: [Int: Set<String>] = [:]
    @State private var typed: [Int: String] = [:]

    /// One single-choice question: clicking an option sends it straight away.
    private var instant: Bool { questions.count == 1 && !questions[0].multi }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    Text(q.text).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options, id: \.self) { o in
                        OptionButton(option: o, selected: picked[q.id, default: []].contains(o.label)) { tap(q, o) }
                    }
                    TextField("Or type your own answer…", text: Binding(
                        get: { typed[q.id, default: ""] }, set: { typed[q.id] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { send() }
                }
            }
            HStack {
                Spacer()
                HandBackButton(id: id, store: store, chats: chats, session: session)
                if !instant {
                    Button("Send") { send() }.buttonStyle(.borderedProminent).disabled(!ready)
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.08)))
    }

    private func tap(_ q: AskQuestion, _ o: AskOption) {
        if instant { store.answer(id, [q.text: o.label]); return }
        var set = picked[q.id, default: []]
        if q.multi {
            if set.contains(o.label) { set.remove(o.label) } else { set.insert(o.label) }
        } else {
            set = [o.label]
        }
        picked[q.id] = set
    }

    private func answer(for q: AskQuestion) -> String {
        let text = typed[q.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let set = picked[q.id, default: []]
        return q.options.map(\.label).filter(set.contains).joined(separator: ", ")
    }

    private var ready: Bool { questions.allSatisfy { !answer(for: $0).isEmpty } }

    private func send() {
        guard ready else { return }
        store.answer(id, questions.reduce(into: [:]) { $0[$1.text] = answer(for: $1) })
    }
}

struct HandBackButton: View {
    let id: UUID
    let store: Store
    let chats: ChatsModel
    let session: SessionInfo

    var body: some View {
        if !session.isFloat {
            Button("Answer in \(session.appName)") {
                store.handBack(id)
                chats.openInApp(session.id)
            }
            .buttonStyle(.link).font(.system(size: 11))
        }
    }
}

struct OptionButton: View {
    let option: AskOption
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(.system(size: 12, weight: .medium))
                if !option.detail.isEmpty {
                    Text(option.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hover ? 0.1 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - One chat

struct ChatView: View {
    let key: String
    @ObservedObject var store: Store
    @ObservedObject var chats: ChatsModel
    @ObservedObject var nav: Nav
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var id: String { chats.resolve(key) }

    var body: some View {
        let id = self.id
        let lines = Array(chats.lines(id).suffix(150))
        let status = chats.status(id)
        let float = chats.float(for: id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { nav.route = .home } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.plain).help("All chats")
                VStack(alignment: .leading, spacing: 1) {
                    Text(chats.title(id)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([chats.project(id), chats.origin(id) ?? "", status.label].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let float, float.alive {
                    Button("End") { float.stop() }.controlSize(.small).help("Stop this chat's Claude process")
                } else if chats.canOpenInApp(id) {
                    Button("Open in Claude") { chats.openInApp(id) }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        if lines.isEmpty, let float {
                            MessageView(line: ChatLine(id: -1, kind: .user, text: float.firstPrompt))
                        }
                        ForEach(lines) { MessageView(line: $0) }
                        if status == .working {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Working…") }
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if let float, !float.alive, !float.lastError.isEmpty, lines.isEmpty {
                            Text(float.lastError).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: lines.last?.id) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: store.sessions[id]?.pending.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let s = store.sessions[id], !s.pending.isEmpty {
                    ScrollView { VStack(spacing: 8) { PendingList(session: s, store: store, chats: chats) } }
                        .frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array((store.queued[id] ?? []).enumerated()), id: \.offset) { i, text in
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(text).lineLimit(1)
                        Spacer()
                        Button { store.unqueue(id, at: i) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
                if let notice = chats.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Reply…", text: $draft, axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.plain).font(.system(size: 13))
                        .focused($focused)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(hint(chats.replyMode(id))).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onAppear {
            chats.notice = nil
            focused = true
        }
    }

    private func hint(_ mode: ReplyMode) -> String {
        switch mode {
        case .direct: return "Return to send · Option-Return for a new line"
        case .queue: return "Claude is busy. Your reply goes in at its next step."
        case .bridge: return "Sends straight into this chat."
        case .handOff: return "This chat is open elsewhere. Sending copies your reply and opens that chat."
        case .resume: return "This chat has ended. Sending continues it here in the float."
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let next = chats.send(text, to: id)
        if next != id { nav.route = .chat(next) }
    }
}

struct MessageView: View {
    let line: ChatLine

    var body: some View {
        switch line.kind {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(String(line.text.prefix(3000))).font(.system(size: 12.5)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.16)))
            }
        case .assistant:
            Text(markdown(String(line.text.prefix(6000)))).font(.system(size: 12.5)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: 5) {
                Image(systemName: "chevron.right.2").font(.system(size: 8, weight: .bold))
                Text(line.text).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: - New chat

struct NewChatView: View {
    @ObservedObject var chats: ChatsModel
    @ObservedObject var nav: Nav
    @State private var folder = ""
    @State private var prompt = ""
    @State private var inApp = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { nav.route = .home } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.plain)
                Text("New chat").font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Folder").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Menu {
                    ForEach(chats.recentFolders, id: \.self) { path in
                        Button(display(path)) { folder = path }
                    }
                    Divider()
                    Button("Choose another folder…") { if let path = chats.chooseFolder() { folder = path } }
                } label: {
                    Text(folder.isEmpty ? "Choose a folder" : display(folder))
                }
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Run in").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: $inApp) {
                    Text("This floating window").tag(false)
                    Text("Claude app").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            TextField("What should Claude do?", text: $prompt, axis: .vertical)
                .lineLimit(4...12).textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
                .onSubmit(start)

            HStack {
                Text(inApp ? "Opens a new chat in Claude with this message ready." : "Return to start · Option-Return for a new line")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Start", action: start).buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.isEmpty)
            }
            Spacer()
        }
        .padding(14)
        .onAppear {
            if folder.isEmpty { folder = chats.recentFolders.first ?? home.path }
            focused = true
        }
    }

    private func display(_ path: String) -> String {
        path == home.path ? "Home (~)" : "\(projectName(path))  —  \(path.replacingOccurrences(of: home.path, with: "~"))"
    }

    private func start() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !folder.isEmpty else { return }
        if let key = chats.startNew(cwd: folder, prompt: text, inApp: inApp) {
            nav.route = .chat(key)
        } else {
            nav.route = .home
        }
    }
}

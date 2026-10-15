import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Colony chat: group chat (# mix) + one direct chat per agent

/// Replaces PromptView when Colony chat is on. Rooms are display-only, like in Colony:
/// every agent still sees the whole conversation, the room only decides what is shown.
struct ColonyChatView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = ColonyStore.shared
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    private var room: String { store.room }
    private var agents: [ColonyAgent] { store.agents }
    private var visible: [ColonyMessage] { store.visible }
    private var currentAgent: ColonyAgent? { store.currentAgent }
    private var busyRooms: Set<String> { store.busyRooms }
    private var offline: Bool { store.offline }
    private var workspaceName: String { store.workspaceName }
    private var workspaceId: String? { store.workspaceId }
    private var errorText: String? { store.errorText }

    /// File dropped on the island, waiting to be sent along with the next message.
    private var pendingFile: (name: String, url: URL)? {
        if case .file(let name, let url)? = state.promptContext, let url { return (name, url) }
        return nil
    }

    /// Window Mochi was dropped on, waiting to be sent along with the next message.
    private var pendingWindow: (app: String, title: String, url: String?)? {
        if case .window(let app, let title, let url)? = state.promptContext { return (app, title, url) }
        return nil
    }

    /// The chat is always laid out at the height the island is about to have (island height minus the header
    /// and its padding) and the island, which clips it, grows over it. Without this the feed is resized on
    /// every frame of the open animation and builds its bubbles while it is happening.
    var body: some View {
        Color.clear.overlay(alignment: .top) {
            content.frame(height: ChatHeight.current(coucouCount: state.chatHistory.count) - 52)
        }
    }

    private var content: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 6) {
                roomRow
                feed
                chipRow
                inputRow
            }
            .padding(.leading, 84).padding(.trailing, 16)
            .padding(.top, 10).padding(.bottom, 14)
        }
        .padding(.bottom, 10)
        .task { await store.reload() }
        .task { await store.loadCommandsIfNeeded() }
    }

    // MARK: Pieces

    private var roomRow: some View {
        HStack(spacing: 6) {
            if naming {
                TextField("Workspace name…", text: $newName)
                    .textFieldStyle(.plain).font(.system(size: 10.5)).frame(width: 130)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.white.opacity(0.1)).clipShape(Capsule())
                    .focused($nameFocused)
                    .onAppear { nameFocused = true }
                    .onSubmit { store.createWorkspace(newName); naming = false; newName = "" }
                    .onExitCommand { naming = false; newName = "" }
                Text("↩ create · esc cancel").font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7078"))
            } else if confirmingDelete, let id = workspaceId {
                Text("Delete \"\(workspaceName)\" and its chat?").font(.system(size: 10.5)).foregroundColor(Color(hex: "#7B8089")).lineLimit(1)
                Button("Delete") { store.deleteWorkspace(id); confirmingDelete = false }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#F87171"))
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.plain).font(.system(size: 10.5)).foregroundColor(Color(hex: "#7B8089"))
            } else if !workspaceName.isEmpty {
                Menu {
                    ForEach(store.workspaces, id: \.id) { w in
                        Button {
                            store.selectWorkspace(w.id)
                        } label: {
                            Text(w.name + (w.id == workspaceId ? "  ✓" : ""))
                        }
                    }
                    Divider()
                    Button("New workspace…") { naming = true }
                    if store.workspaces.count > 1 {
                        Button("Delete this workspace…", role: .destructive) { confirmingDelete = true }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(workspaceName)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: "#7B8089"))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Spacer()
            roomButton(id: "auto", color: "#8B8FFB", label: "Group chat", tip: "Group chat: Colony picks who answers") {
                Image(systemName: "person.3.fill").font(.system(size: 11)).foregroundColor(.white)
            }
            ForEach(store.shownAgents) { a in
                roomButton(id: a.id, color: a.color, label: a.name, tip: "\(a.name): \(a.when)") {
                    Circle().fill(Color(hex: a.color)).frame(width: 14, height: 14)
                }
            }
        }
        .frame(height: 26)
    }

    /// The selected room also shows its name, so the dots are never the only way to tell agents apart.
    private func roomButton<Content: View>(id: String, color: String, label: String, tip: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        Button {
            store.room = id
            SoundEngine.shared.play("blip")
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    content()
                    if room == id && id != "auto" {
                        Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(Color(hex: "#E6E8EB"))
                    }
                }
                .padding(.horizontal, room == id && id != "auto" ? 8 : 0)
                .frame(minWidth: 26, minHeight: 24)
                .background(room == id ? Color.white.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(room == id ? Color(hex: color).opacity(0.7) : Color.clear, lineWidth: 1))
                if busyRooms.contains(id) {
                    Circle().fill(Color(hex: "#F5A524")).frame(width: 7, height: 7)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    @ViewBuilder private var feed: some View {
        if offline {
            note("Colony isn't running. Start it with the `colony` command.")
        } else if visible.isEmpty && !busyRooms.contains(room) {
            guide
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Lazy: only the bubbles on screen are laid out, so a long chat stays as fast as a short one.
                    LazyVStack(alignment: .leading, spacing: 6) {
                        // Only the latest 40 are built: switching rooms costs the same however long the chat is.
                        ForEach(visible.suffix(40)) { m in
                            ColonyBubble(m: m, showName: room == "auto", workspaceId: workspaceId ?? "").equatable().id(m.id)
                        }
                        if busyRooms.contains(room) {
                            LiveBubble(live: store.live, room: room) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        if busyRooms.contains(room) {
                            LiveTyping(live: store.live)
                        }
                        if let e = errorText {
                            Text(e).font(.system(size: 11)).foregroundColor(Color(hex: "#FF8D97"))
                        }
                        if let r = store.reminder {
                            Button { store.reminder = nil } label: {
                                Text("⏰ " + r + "  ✕").font(.system(size: 12, weight: .medium)).foregroundColor(Color(hex: "#FFE08A"))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color(hex: "#FFD84D").opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        // Always the last child: scrolling to it lands on the true end however tall the bubbles are.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 2)
                }
                // A message arrived or was sent (yours or an agent's): follow it to the bottom.
                .onChange(of: visible.count) { _ in jumpToLatest(proxy) }
                // Opening the chat or switching room: a fresh scroll view per room (no offset carried over from the
                // other room), starting at the newest message.
                .onAppear { jumpToLatest(proxy) }
                .onChange(of: busyRooms) { _ in jumpToLatest(proxy) }
                .id(room)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) {
        for delay in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Empty room: who is right for what, taken from each agent's "when to answer" rule.
    private var guide: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(room == "auto" ? "Group chat · Colony picks who answers" : "\(currentAgent?.name ?? "Agent")'s room · everyone still sees the whole chat")
                .font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: "#9AA0A8"))
            ForEach(room == "auto" ? agents : agents.filter { $0.id == room }) { a in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Color(hex: a.color)).frame(width: 7, height: 7).padding(.top, 4)
                    (Text(a.name + "  ").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#D5D8DC"))
                     + Text(a.when).font(.system(size: 11)).foregroundColor(Color(hex: "#7B8089")))
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func note(_ s: String) -> some View {
        VStack { Spacer(); Text(s).font(.system(size: 11)).foregroundColor(Color(hex: "#6B7078")); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private var chipRow: some View {
        HStack {
            Spacer()
            if room == "auto" {
                // One small dot + percent per agent: enough to see who is getting full.
                ForEach(agents) { a in contextMeter(a) }
                chipLabel(color: "#8B8FFB", text: "Colony decides")
            } else if let a = currentAgent {
                contextMeter(a, wide: true)
                Menu {
                    ForEach(store.models) { m in
                        Button {
                            store.setModel(m.id, forAgent: a.id)
                        } label: {
                            Text(m.label + (m.id == a.model ? "  ✓" : ""))
                        }
                    }
                } label: {
                    chipLabel(color: a.color, text: "\(a.model) · \(a.name)", chevron: true)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .task { await store.loadModelsIfNeeded() }
            }
        }
        .padding(.horizontal, 10)
    }

    /// How full an agent's context is: a ring and a percent, amber from 70 %, red from 90 %. The tooltip has the tokens.
    private func contextMeter(_ a: ColonyAgent, wide: Bool = false) -> some View {
        let c = store.contexts[a.id]
        let tint = (c?.fraction ?? 0) >= 0.9 ? "#F87171" : (c?.fraction ?? 0) >= 0.7 ? "#F5A524" : a.color
        return HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
                Circle().trim(from: 0, to: c?.fraction ?? 0)
                    .stroke(Color(hex: tint), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text(wide ? "\(c?.label ?? "–") context" : "\(a.name) \(c?.label ?? "–")")
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#7B8089"))
        }
        .help(c.map { "\(a.name): \($0.detail)" } ?? "\(a.name): no context yet")
    }

    private func chipLabel(color: String, text: String, chevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: color)).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundColor(Color(hex: "#7B8089"))
            if chevron {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundColor(Color(hex: "#5C6370"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(0.06)).clipShape(Capsule())
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let f = pendingFile {
                HStack(spacing: 5) {
                    Image(systemName: "paperclip").font(.system(size: 10))
                    Text(f.name).font(.system(size: 10.5)).lineLimit(1)
                    Button { state.promptContext = nil } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                        .buttonStyle(.plain)
                }
                .foregroundColor(Color(hex: "#B9BDC4"))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.white.opacity(0.07)).clipShape(Capsule())
            }
            if let w = pendingWindow {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow").font(.system(size: 10))
                    Text(w.title.isEmpty ? w.app : "\(w.app) · \(w.title)").font(.system(size: 10.5)).lineLimit(1)
                    Button { state.promptContext = nil } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                        .buttonStyle(.plain)
                }
                .foregroundColor(Color(hex: "#B9BDC4"))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.white.opacity(0.07)).clipShape(Capsule())
            }
            ColonyComposer(placeholder: room == "auto" ? "Message the team…" : "Message \(currentAgent?.name ?? "agent")…",
                           commands: store.commands, canSend: workspaceId != nil, onSend: send)
        }
    }

    // MARK: Send

    private func send(_ q: String) {
        if let w = pendingWindow {
            // The window's text goes along as a small text file, like a dropped file, so the bubble stays short.
            state.promptContext = nil
            Task { @MainActor in
                let file = ColonyWindowContext.file(app: w.app, title: w.title, url: w.url)
                store.send(q, file: file)
                if let file { try? await Task.sleep(nanoseconds: 60_000_000_000); ColonyWindowContext.cleanup(file) }
            }
            return
        }
        store.send(q, file: pendingFile?.url)
        if pendingFile != nil { state.promptContext = nil }
    }
}


// MARK: - Pieces that redraw on their own

/// One message. Equatable, so SwiftUI skips it when nothing about it changed (its markdown is the costly part).
struct ColonyBubble: View, Equatable {
    let m: ColonyMessage
    let showName: Bool
    let workspaceId: String

    var body: some View {
        if m.isUser {
            HStack { Spacer(minLength: 32)
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(m.attachments) { ColonyAttachmentView(attachment: $0, workspaceId: workspaceId) }
                    Text(m.text).font(.system(size: 12.5)).foregroundColor(Color(hex: "#F1F2F4"))
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if showName, let name = m.agentName {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: ColonyService.color(forAgent: m.agentId ?? name))).frame(width: 6, height: 6)
                        Text(name + (m.confidence.map { " · \(Int($0 * 100))%" } ?? ""))
                            .font(.system(size: 10.5)).foregroundColor(Color(hex: "#8A8F98"))
                    }
                }
                ChatMarkdownView(markdown: m.text)
                if let s = m.workedSeconds, s > 0 { ColonyWorkedRow(seconds: s, steps: m.steps, count: m.stepCount) }
                if !m.saved.isEmpty { ColonySavedChip(saved: m.saved).padding(.top, 2) }
                if !m.sources.isEmpty { ColonySourcesChip(sources: m.sources).padding(.top, 2) }
            }
        }
    }
}

/// The reply as it is being written. Plain text while streaming (markdown is applied once the reply is final),
/// so a growing paragraph is cheap to lay out.
private struct LiveBubble: View {
    @ObservedObject var live: LiveReply
    let room: String
    let onGrow: () -> Void
    @State private var lastFollow = Date.distantPast

    var body: some View {
        // Follow the text down a few times a second, not on every token: a scroll per token fights the reader and, in a
        // lazy list whose last bubble is still growing, scrolls past the content (the chat looks blank).
        content.onChange(of: live.partial?.text.count) { _ in
            guard Date().timeIntervalSince(lastFollow) > 0.4 else { return }
            lastFollow = Date()
            onGrow()
        }
    }

    @ViewBuilder private var content: some View {
        if let p = live.partial, room == "auto" || p.agentId == room {
            VStack(alignment: .leading, spacing: 3) {
                if room == "auto" {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: ColonyService.color(forAgent: p.agentId))).frame(width: 6, height: 6)
                        Text(p.agentName).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8A8F98"))
                    }
                }
                Text(p.text).font(.system(size: 12.5)).foregroundColor(Color(hex: "#B0B5BE"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id("live")
        }
    }
}

/// The typing dots (only until the first words of the reply arrive) and, under them, what the agent is doing now.
private struct LiveTyping: View {
    @ObservedObject var live: LiveReply

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if live.partial == nil { HStack { TypingDotsView(); Spacer(minLength: 32) } }
            if let status = live.status {
                Text(status).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8A8F98"))
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// The message box. It keeps its own text, so a keystroke redraws this box and nothing else.
struct ColonyComposer: View {
    let placeholder: String
    let commands: [GatewayCommand]
    let canSend: Bool
    let onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// "/" or "/st": the commands that start like what is typed (until the first space, then it is an argument).
    private var matches: [GatewayCommand] {
        guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
        let typed = String(text.dropFirst()).lowercased()
        return Array(commands.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }.prefix(40))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !matches.isEmpty { commandMenu }
            box
        }
    }

    private var commandMenu: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { c in
                    Button { text = "/" + c.name + " "; focused = true } label: {
                        HStack(spacing: 8) {
                            Text("/" + c.name + (c.usage.isEmpty ? "" : " " + c.usage))
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(hex: "#E6E8EB"))
                            Text(c.description).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8A8F98")).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 112)
        .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var box: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused).onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#0B0C0E"))
            }
            .buttonStyle(SendButtonStyle())
            .disabled(empty || !canSend)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .onAppear { focused = true }
    }

    private func send() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, canSend else { return }
        text = ""
        onSend(q)
    }
}


// MARK: - Window context for Colony agents

/// What an agent gets when Mochi is dropped on a window: app, title, URL and the text on screen.
/// Browsers give the page text through AppleScript (Safari needs "Allow JavaScript from Apple Events",
/// Chrome/Edge/Arc "Allow JavaScript from Apple Events" in the View > Developer menu); every other app,
/// and a browser that refuses, is read through Accessibility.
enum ColonyWindowContext {
    private static let maxChars = 24_000
    /// AppleScript per browser; `%@` is the JavaScript run in the front tab.
    private static let pageScripts: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return do JavaScript \"%@\" in current tab of front window",
        "com.google.Chrome": "tell application \"Google Chrome\" to return execute active tab of front window javascript \"%@\"",
        "company.thebrowser.Browser": "tell application \"Arc\" to return execute active tab of front window javascript \"%@\"",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return execute active tab of front window javascript \"%@\"",
    ]

    /// Google Sheets, Docs and Slides draw their content on a canvas, so the page has no text. Their own export
    /// endpoint gives it back, and a request made from the page itself carries the user's sign-in.
    private static func googleExportJS(_ url: String?) -> String? {
        guard let url, let c = URLComponents(string: url), c.host == "docs.google.com" else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "d" else { return nil }
        let id = parts[2]
        guard id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        var path: String
        switch parts[0] {
        case "spreadsheets":
            path = "/spreadsheets/d/\(id)/export?format=csv"
            // the open tab: gid is in the fragment or the query
            let gid = (c.fragment ?? "").split(separator: "=").last.map(String.init)
                ?? c.queryItems?.first { $0.name == "gid" }?.value
            if let gid, gid.allSatisfy(\.isNumber) { path += "&gid=" + gid }
        case "document": path = "/document/d/\(id)/export?format=txt"
        case "presentation": path = "/presentation/d/\(id)/export?format=txt"
        default: return nil
        }
        return "var x=new XMLHttpRequest();x.open('GET','\(path)',false);x.send();x.status==200?x.responseText:''"
    }

    /// A local file shown in a browser (a PDF, an image, a text file) is sent as itself: its text is not on screen.
    private static func localFile(_ url: String?) -> URL? {
        guard let url, url.hasPrefix("file://"), let u = URL(string: url), u.isFileURL else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? nil
        guard let size, size > 0, size <= 20_000_000 else { return nil }
        return u
    }

    /// Removes a file made by `file(...)`; the user's own file (a local PDF) is never touched.
    static func cleanup(_ file: URL) {
        let dir = file.deletingLastPathComponent()
        guard dir.lastPathComponent.hasPrefix("colony-window-") else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// The file to send with the message: the local file itself, or a temporary .txt with the window's text.
    static func file(app: String, title: String, url: String?) -> URL? {
        if let local = localFile(url) { return local }
        var out = "Window context (the window the user dropped Mochi on)\nApp: \(app)\nWindow: \(title)\n"
        if let url { out += "URL: \(url)\n" }
        var hint: String?
        let running = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == app && $0.activationPolicy == .regular }
        if let running, var text = pageText(of: running, url: url, hint: &hint) ?? accessibilityText(of: running), !text.isEmpty {
            if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n[truncated]" }
            out += "\nText on screen:\n\(text)\n"
            if let hint { out += "\n(\(hint))\n" }
        } else if !AXIsProcessTrusted() {
            // Asks macOS to show the Accessibility prompt; a rebuilt, unsigned Coucou has to be allowed again.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            out += "\n(Coucou has no Accessibility permission, so the window text could not be read.)\n"
        } else {
            out += "\n(The text of the window could not be read.)\n"
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("colony-window-\(UUID().uuidString)")
        let name = "Window - \(app).txt".replacingOccurrences(of: "/", with: "-")
        let file = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try out.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch { return nil }
    }

    private static func pageText(of app: NSRunningApplication, url: String?, hint: inout String?) -> String? {
        guard let id = app.bundleIdentifier, let template = pageScripts[id] else { return nil }
        let js = googleExportJS(url) ?? "document.body.innerText"
        let script = String(format: template, js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let message = error?[NSAppleScript.errorMessage] as? String, message.contains("Apple Events") {
            hint = "The page text could not be read: in the browser, turn on View > Developer > Allow JavaScript from Apple Events."
        }
        guard error == nil, let s = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func accessibilityText(of app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        // Electron and Chromium apps (Claude desktop, Chrome, VS Code, Slack) build their accessibility tree only on request.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
                || AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        var lines: [String] = []
        var chars = 0
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 60, visited < 8000, chars < maxChars else { return }
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if let r = role as? String, ["AXStaticText", "AXTextArea", "AXTextField"].contains(r) {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
                   let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != lines.last {
                    lines.append(s)
                    chars += s.count + 1
                }
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
               let children = kids as? [AXUIElement] {
                for c in children { walk(c, depth: depth + 1) }
            }
        }
        // swiftlint:disable:next force_cast
        let window = ref as! AXUIElement
        walk(window, depth: 0)
        if lines.isEmpty {
            // The tree of an Electron/Chromium app is built after the first request: give it a moment and read again.
            Thread.sleep(forTimeInterval: 0.7)
            visited = 0
            walk(window, depth: 0)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}


// MARK: - Sources

/// "🌐 15 sources" under a reply that used the web; click lists the pages the agent really got, each opens in the browser.
private struct ColonySourcesChip: View {
    let sources: [ColonySource]
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                HStack(spacing: -4) {
                    ForEach(Array(sources.prefix(3))) { s in
                        Text(String((s.site.first ?? "?").uppercased()))
                            .font(.system(size: 7.5, weight: .bold)).foregroundColor(Color(hex: "#0B0C0E"))
                            .frame(width: 14, height: 14).background(Color(hex: "#D7DAE0")).clipShape(Circle())
                            .overlay(Circle().stroke(Color(hex: "#1B1C1F"), lineWidth: 1))
                    }
                }
                Image(systemName: "globe").font(.system(size: 9.5))
                Text("\(sources.count) source\(sources.count == 1 ? "" : "s")").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(Color(hex: "#B9BDC4"))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.08)).clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { ColonySourcesList(sources: sources) }
    }
}

private struct ColonySourcesList: View {
    let sources: [ColonySource]

    /// Sources in the order of the searches that found them.
    private var queries: [String] {
        var seen: [String] = []
        for s in sources where !seen.contains(s.query) { seen.append(s.query) }
        return seen
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sources").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#F1F2F4"))
                ForEach(queries, id: \.self) { q in
                    if !q.isEmpty {
                        Text("Results for “\(q)”").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8A8F98"))
                    }
                    ForEach(sources.filter { $0.query == q }) { row($0) }
                }
            }
            .padding(14)
        }
        .frame(width: 340, height: min(CGFloat(sources.count) * 78 + 70, 420))
        .background(Color(hex: "#1B1C1F"))
    }

    private func row(_ s: ColonySource) -> some View {
        Button {
            if let u = URL(string: s.url) { NSWorkspace.shared.open(u) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(String((s.site.first ?? "?").uppercased()))
                        .font(.system(size: 8, weight: .bold)).foregroundColor(Color(hex: "#0B0C0E"))
                        .frame(width: 15, height: 15).background(Color(hex: "#D7DAE0")).clipShape(Circle())
                    Text(s.site).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8A8F98")).lineLimit(1)
                }
                Text(s.title).font(.system(size: 12, weight: .medium)).foregroundColor(Color(hex: "#F1F2F4"))
                    .lineLimit(2).multilineTextAlignment(.leading)
                if !s.snippet.isEmpty {
                    Text(s.snippet).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8A8F98"))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.url)
    }
}


// MARK: - Attachments and saved files

/// What went with the user's message: a small picture for an image, a file chip for the rest.
private struct ColonyAttachmentView: View {
    let attachment: ColonyAttachment
    let workspaceId: String

    private var url: URL? {
        attachment.localURL ?? URL(string: ColonyService.baseURL + "/api/workspaces/\(workspaceId)/attachments/\(attachment.id)")
    }

    var body: some View {
        if attachment.kind == "image", let url {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { Color.white.opacity(0.08) }
            }
            .frame(width: 120, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 5) {
                Image(systemName: attachment.kind == "pdf" ? "doc.richtext" : "paperclip").font(.system(size: 10))
                Text(attachment.name).font(.system(size: 10.5)).lineLimit(1)
            }
            .foregroundColor(Color(hex: "#B9BDC4"))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.white.opacity(0.1)).clipShape(Capsule())
        }
    }
}

/// "Saved to memory · USER.md" under a reply whose write/edit tool really succeeded.
private struct ColonySavedChip: View {
    let saved: [ColonySaved]

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(Color(hex: "#7BD88F"))
            Text((saved.contains { $0.isMemory } ? "Saved to memory" : "Wrote") + " · " + saved.map(\.name).joined(separator: ", "))
                .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(Color(hex: "#B9BDC4"))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.white.opacity(0.07)).clipShape(Capsule())
    }
}

/// "Worked for 11s · 2 steps" under a reply; with steps it opens a list of what the agent ran, read and wrote.
struct ColonyWorkedRow: View {
    let seconds: Double
    let steps: [ColonyStep]
    let count: Int
    @State private var open = false

    private var label: String {
        "Worked for \(Int(seconds))s" + (count > 0 ? " · \(count) step\(count == 1 ? "" : "s")" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if steps.isEmpty {
                Text(label).font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7078"))
            } else {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text(label)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: open ? "#B9BDC4" : "#6B7078"))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what the agent did")
                if open {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(steps) { ColonyStepCard(step: $0) }
                    }
                }
            }
        }
    }
}

struct ColonyStepCard: View {
    let step: ColonyStep

    private var icon: String {
        switch step.kind {
        case "command": return "terminal"
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "skill": return "sparkles"
        case "memory": return "brain"
        case "web": return "globe"
        case "delegate": return "person.2"
        case "connector": return "puzzlepiece.extension"
        default: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).frame(width: 12)
                    .foregroundColor(Color(hex: step.ok ? "#8B8FFB" : "#FF8D97"))
                Text(step.title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#E6E8EB"))
                if !step.ok {
                    Text("failed").font(.system(size: 9.5, weight: .medium)).foregroundColor(Color(hex: "#FF8D97"))
                }
                Spacer(minLength: 0)
                if let ms = step.ms {
                    Text(ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms")
                        .font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7078"))
                }
            }
            if !step.detail.isEmpty {
                Text(step.detail).font(.system(size: 10.5, design: .monospaced)).foregroundColor(Color(hex: "#C8CDD4"))
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !step.output.isEmpty {
                Text(step.output).font(.system(size: 10, design: .monospaced)).foregroundColor(Color(hex: "#7B8089"))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

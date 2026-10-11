import SwiftUI

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

    var body: some View {
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
        .task { await store.pollActivity(state: state) }
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
                            ColonyBubble(m: m, showName: room == "auto").equatable().id(m.id)
                        }
                        if busyRooms.contains(room) {
                            LiveBubble(live: store.live, room: room) { proxy.scrollTo("live", anchor: .bottom) }
                        }
                        if busyRooms.contains(room) {
                            LiveTyping(live: store.live).id("typing")
                        }
                        if let e = errorText {
                            Text(e).font(.system(size: 11)).foregroundColor(Color(hex: "#FF8D97"))
                        }
                        if let r = store.reminder {
                            Button { store.reminder = nil } label: {
                                Text("⏰ " + r).font(.system(size: 12, weight: .medium)).foregroundColor(Color(hex: "#FFE08A"))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color(hex: "#FFD84D").opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: visible.count) { _ in
                    if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: busyRooms) { _ in proxy.scrollTo("typing", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
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
                chipLabel(color: "#8B8FFB", text: "Colony decides · \(agents.count) agents")
            } else if let a = currentAgent {
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
            ColonyComposer(placeholder: room == "auto" ? "Message the team…" : "Message \(currentAgent?.name ?? "agent")…",
                           commands: room == "auto" ? [] : store.commands, canSend: workspaceId != nil, onSend: send)
        }
    }

    // MARK: Send

    private func send(_ q: String) {
        store.send(q, file: pendingFile?.url)
        if pendingFile != nil { state.promptContext = nil }
    }
}


// MARK: - Pieces that redraw on their own

/// One message. Equatable, so SwiftUI skips it when nothing about it changed (its markdown is the costly part).
private struct ColonyBubble: View, Equatable {
    let m: ColonyMessage
    let showName: Bool

    var body: some View {
        if m.isUser {
            HStack { Spacer(minLength: 32)
                Text(m.text).font(.system(size: 12.5)).foregroundColor(Color(hex: "#F1F2F4"))
                    .textSelection(.enabled)
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
                if let s = m.workedSeconds, s > 0 {
                    Text("Worked for \(Int(s))s" + (m.stepCount > 0 ? " · \(m.stepCount) steps" : ""))
                        .font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7078"))
                }
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

    var body: some View {
        content.onChange(of: live.partial?.text.count) { _ in onGrow() }
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
private struct ColonyComposer: View {
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

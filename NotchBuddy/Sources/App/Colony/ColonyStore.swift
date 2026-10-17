import SwiftUI

/// The reply being written right now. Its own object so that only the live bubble redraws as text arrives,
/// not the whole chat (every message's markdown would be laid out again on each update).
@MainActor
final class LiveReply: ObservableObject {
    @Published var partial: ColonyPartial?
    /// What the agent is doing right now ("Writer · Used skill: zebra-protocol"); nil when idle.
    @Published var status: String?
}

/// One shared copy of the Colony conversation, so the Home card and the chat show the same rooms
/// and nothing is lost when the island swaps views.
@MainActor
final class ColonyStore: ObservableObject {
    static let shared = ColonyStore()

    @Published var workspaceId: String?
    @Published var workspaces: [(id: String, name: String)] = []
    @Published var models: [ColonyModel] = []
    @Published var workspaceName = ""
    @Published var agents: [ColonyAgent] = []
    @Published var messages: [ColonyMessage] = []
    @Published var room = "auto"            // "auto" = group chat, otherwise an agent id
    @Published var busyRooms: Set<String> = []
    /// The Gateway's slash commands (the "/" menu in an agent's chat).
    @Published var commands: [GatewayCommand] = []
    /// Turns running in the Gateway right now (their status comes from the Gateway, not from Colony's activity poll).
    private var nativeTurns = 0
    /// The send in flight and the Gateway session it is using, so the stop button can end both.
    private var sendTask: Task<Void, Never>?
    private var runningTurn: (agentId: String, session: String)?
    @Published var offline = false
    @Published var errorText: String?
    @Published var contexts: [String: ColonyContext] = [:]     // agent id -> how full its context is
    @Published var activity = ColonyActivity()
    /// A reminder an agent set (OpenClaw's `cron`) that just fired; shown in the chat until tapped away.
    @Published var reminder: String?
    private var reminderTask: Task<Void, Never>?

    let live = LiveReply()
    /// Agents the user switched off in Settings → Active pills ("<workspace id>:<agent id>"). Only hides them in
    /// Home and the room row; the decider and the team itself are untouched.
    @Published var hiddenAgents: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "colonyHiddenAgents") ?? [])
    private var loading = false

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "colonyChatEnabled") as? Bool ?? true
    }

    private func key(_ a: ColonyAgent) -> String { (workspaceId ?? "") + ":" + a.id }
    func isHidden(_ a: ColonyAgent) -> Bool { hiddenAgents.contains(key(a)) }
    func setHidden(_ a: ColonyAgent, _ hidden: Bool) {
        if hidden { hiddenAgents.insert(key(a)) } else { hiddenAgents.remove(key(a)) }
        UserDefaults.standard.set(Array(hiddenAgents), forKey: "colonyHiddenAgents")
        if hidden, room == a.id { room = "auto" }
    }
    /// The agents shown in Home and the room row.
    var shownAgents: [ColonyAgent] { agents.filter { !isHidden($0) } }

    var currentAgent: ColonyAgent? { agents.first { $0.id == room } }
    var visible: [ColonyMessage] { messages.filter { $0.channel == room } }

    /// Agents as Coucou tasks so Home can reuse the existing pills (same look, same mini Mochi).
    var tasks: [AgentTask] {
        shownAgents.map { a in
            var state: BotState = busyRooms.contains(a.id) ? .working : .idle
            if activity.active, activity.agentName == a.name { state = ColonyService.botState(for: activity) ?? .working }
            return AgentTask(id: a.id, name: a.name, color: a.color, state: state, steps: [], source: .agent)
        }
    }

    func reload() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        guard let all = await ColonyService.loadWorkspaces() else { offline = true; return }
        offline = false
        workspaces = all.map { ($0.id, $0.name) }
        let saved = UserDefaults.standard.string(forKey: "colonyWorkspaceId")
        let ws = all.first { $0.id == (workspaceId ?? saved) } ?? all[0]
        if workspaceId != ws.id { messages = [] }
        workspaceId = ws.id; workspaceName = ws.name; agents = ws.agents
        if room != "auto", !ws.agents.contains(where: { $0.id == room }) { room = "auto" }
        let fresh = await ColonyService.loadMessages(workspaceId: ws.id)
        // Keep messages still being sent (not on the server yet) instead of dropping them on a refresh.
        messages = busyRooms.isEmpty ? fresh : fresh + messages.filter { m in !fresh.contains { $0.id == m.id } && m.isLocalPending }
        await refreshContexts()
    }

    func refreshContexts() async {
        guard let ws = workspaceId else { return }
        let fresh = await ColonyService.fetchContext(workspaceId: ws)
        if !fresh.isEmpty, fresh != contexts { contexts = fresh }
    }

    func selectWorkspace(_ id: String) {
        guard id != workspaceId else { return }
        UserDefaults.standard.set(id, forKey: "colonyWorkspaceId")
        workspaceId = id
        room = "auto"
        messages = []
        Task { await reload() }
    }

    /// New workspace with a copy of the current team; switches to it.
    func createWorkspace(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        errorText = nil
        Task {
            do {
                let id = try await ColonyService.createWorkspace(name: clean, copyFrom: workspaceId)
                UserDefaults.standard.set(id, forKey: "colonyWorkspaceId")
                workspaceId = id; room = "auto"; messages = []
                await reload()
            } catch { errorText = error.localizedDescription }
        }
    }

    /// Deletes a workspace; if it was the open one, the app moves to another.
    func deleteWorkspace(_ id: String) {
        errorText = nil
        Task {
            do {
                try await ColonyService.deleteWorkspace(id: id)
                if workspaceId == id {
                    UserDefaults.standard.removeObject(forKey: "colonyWorkspaceId")
                    workspaceId = nil; room = "auto"; messages = []
                }
                await reload()
            } catch { errorText = error.localizedDescription }
        }
    }

    func loadCommandsIfNeeded() async {
        if commands.isEmpty { commands = await GatewayClient.shared.commands() }
    }

    func loadModelsIfNeeded() async {
        if models.isEmpty { models = await ColonyService.fetchModels() }
    }

    /// Changes one agent's model (the chat chip's menu). Everything else about the agent is left as it is.
    func setModel(_ modelId: String, forAgent agentId: String) {
        guard let ws = workspaceId else { return }
        errorText = nil
        Task {
            var roles = await ColonyService.fetchRoles(workspaceId: ws)
            guard let i = roles.firstIndex(where: { $0["id"] as? String == agentId }) else { return }
            roles[i]["model"] = modelId
            do {
                try await ColonyService.saveRoles(workspaceId: ws, roles: roles)
                await reload()
            } catch { errorText = error.localizedDescription }
        }
    }

    /// The stop button: ends the reply being written (in the Gateway too) and frees the chat.
    func stop() {
        sendTask?.cancel()
        if let t = runningTurn { Task { await GatewayClient.shared.abort(agentId: t.agentId, session: t.session) } }
        busyRooms.removeAll()
        live.partial = nil; live.status = nil
    }

    func send(_ text: String, file: URL?) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let ws = workspaceId else { return }
        let target = room
        errorText = nil
        let localId = "local-" + UUID().uuidString
        let shown = file.map { f in
            [ColonyAttachment(id: localId, name: f.lastPathComponent,
                              kind: ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(f.pathExtension.lowercased()) ? "image" : "file",
                              localURL: f)]
        } ?? []
        messages.append(ColonyMessage(id: localId, isUser: true, text: q, channel: target, agentId: nil,
                                      agentName: nil, confidence: nil, workedSeconds: nil, stepCount: 0, attachments: shown))
        busyRooms.insert(target)
        sendTask = Task {
            defer { busyRooms.remove(target) }
            do {
                // A message runs in the Gateway directly (live status, its own approvals, images and PDFs as attachments), in
                // an agent's own chat and in the group chat (Colony's decider picks who answers). If that is not possible
                // (files the agents cannot read, Gateway not reachable) it goes through Colony as before.
                var ids: [String] = []
                if let file, !q.hasPrefix("/") { ids.append(try await ColonyService.upload(workspaceId: ws, fileURL: file)) }     // a command carries no file
                if UserDefaults.standard.object(forKey: "colonyDirectGateway") as? Bool ?? true {
                    if target == "auto", q.hasPrefix("/"), ids.isEmpty, !agents.isEmpty {
                        if await runCommandForTeam(q, workspaceId: ws) { await reload(); return }
                    }
                    if target == "auto" { live.status = "Choosing who answers…" }       // the decider runs inside prepare
                    if let turn = await ColonyService.prepareTurn(workspaceId: ws, text: q, room: target, attachments: ids) {
                        // in an agent's own chat a slash command goes as typed
                        var next: ColonyService.Handoff?
                        if await runDirect(turn, room: target, text: target != "auto" && q.hasPrefix("/") ? q : turn.message,
                                           onHandoff: { next = $0 }) {
                            await reload()
                            // The server has your message now. Every later reload in this chain happens while the room is still
                            // busy, which keeps unsent local messages, so drop this one or it shows twice at the end.
                            messages.removeAll { $0.id == localId }
                            // The reply ended with "@Name task" for a teammate who accepts work: that teammate answers
                            // next, in the same conversation (Colony allows at most 3 handoffs after the user's message).
                            while let h = next, !Task.isCancelled {
                                next = nil
                                guard let t = await ColonyService.prepareTurn(workspaceId: ws, text: h.message, room: target,
                                                                              attachments: ids, handoff: h) else { break }
                                _ = await runDirect(t, room: target, text: t.message, onHandoff: { next = $0 })
                                await reload()
                            }
                            busyRooms.remove(target)
                            return
                        }
                    }
                    live.status = nil
                }
                guard !Task.isCancelled else { return }       // stopped before the reply started
                messages.append(try await ColonyService.send(workspaceId: ws, text: q, channel: target, attachments: ids))
                live.partial = nil
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// One turn with the Gateway: what it reports (status, tools, reply as it is written, questions) goes straight to the chat.
    /// False when the Gateway could not be reached at all (nothing happened: the caller sends it the normal way).
    private func runDirect(_ turn: ColonyService.NativeTurn, room: String, text: String,
                           finish: ((String, Bool) -> Void)? = nil,
                           onHandoff: ((ColonyService.Handoff) -> Void)? = nil) async -> Bool {
        nativeTurns += 1
        runningTurn = (turn.agentId, turn.session)
        defer {
            runningTurn = nil
            nativeTurns -= 1; live.partial = nil; live.status = nil
            Task { await refreshContexts() }
        }
        var reply = ""
        var failed = false
        var heardFromGateway = false
        var usedTool = false
        live.status = "\(turn.roleName) · Preparing…"

        /// One chat.send and its events; returns the final text.
        func consume(_ message: String, attachments: [[String: Any]]) async throws -> String {
            var text = ""
            for try await event in await GatewayClient.shared.chat(agentId: turn.agentId, session: turn.session,
                                                                  text: message, model: turn.model,
                                                                  permissionMode: turn.permissionMode, cwd: turn.cwd,
                                                                  attachments: attachments) {
                heardFromGateway = true
                switch event {
                case .status(let s):
                    live.status = "\(turn.roleName) · " + Self.statusText(s)
                case .delta(let d):
                    text += d
                    live.partial = ColonyPartial(agentId: turn.roleId, agentName: turn.roleName, text: text)
                case .tool(let title, let detail, let done, _):
                    usedTool = true
                    live.status = "\(turn.roleName) · " + (done ? "Finished: " : "") + title + (detail.isEmpty ? "" : ": " + detail)
                case .approval(let ask):
                    showGatewayApproval(ask, agent: turn.roleName)
                case .final(let full):
                    text = full
                }
            }
            return text
        }

        do {
            reply = try await consume(text, attachments: turn.attachments)
            // A small model sometimes ends the turn right after a tool with nothing readable ("}"). Ask once more,
            // in the same session where the tool result is already, for the answer in words.
            if usedTool, !Self.hasReadableAnswer(reply) {
                live.partial = nil
                live.status = "\(turn.roleName) · Writing the answer…"
                let again = try await consume(Self.summarizeNudge, attachments: [])
                if Self.hasReadableAnswer(again) { reply = again }
            }
        } catch {
            failed = true
            if heardFromGateway { errorText = error.localizedDescription }
        }
        if Task.isCancelled { failed = true }
        clearGatewayApproval()
        if let finish { finish(reply, failed) }       // the caller closes the turn (a command for the whole team)
        else if let h = await ColonyService.finishTurn(id: turn.turnId, reply: reply, failed: failed) { onHandoff?(h) }
        else if !failed { announce(turn.roleName, reply) }   // the last reply of a chain, not each hop
        return heardFromGateway
    }

    /// The "finished" sound, and the island's finished card when the island is closed (open = you can see the chat).
    private func announce(_ who: String, _ reply: String) {
        let text = DiffEngine.toOneLine(reply)
        guard !text.isEmpty else { return }
        SoundEngine.shared.play("finish")
        let state = AppState.shared
        guard state.mode != .expanded else { return }
        state.finishedNote = (who, text)
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.finished)
        Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if state.finishedNote?.text == text { state.finishedNote = nil } }
    }

    /// A slash command in the group chat goes to every agent (each in its group session), one after another, and the
    /// answers are saved as one message: "/new" starts the whole team over, "/status" shows each agent.
    /// False when no agent could be reached (the caller falls back to the normal way).
    private func runCommandForTeam(_ command: String, workspaceId ws: String) async -> Bool {
        var answers: [(turn: ColonyService.NativeTurn, reply: String, failed: Bool)] = []
        for a in agents {
            guard let turn = await ColonyService.prepareTurn(workspaceId: ws, text: command, room: "auto", agent: a.id) else { continue }
            var reply = "", failed = true
            _ = await runDirect(turn, room: "auto", text: command) { r, f in reply = r; failed = f }
            answers.append((turn, reply, failed))
        }
        let ok = answers.filter { !$0.failed && !$0.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !answers.isEmpty else { return false }
        for a in answers {      // only the first answer carries the saved message; the others are closed
            if let first = ok.first, first.turn.turnId == a.turn.turnId {
                let text = ok.map { "**\($0.turn.roleName)**\n\($0.reply)" }.joined(separator: "\n\n")
                await ColonyService.finishTurn(id: a.turn.turnId, reply: text, failed: false)
            } else {
                await ColonyService.finishTurn(id: a.turn.turnId, reply: nil, failed: true)
            }
        }
        return true
    }

    private static let summarizeNudge =
        "Using the tool results above, answer my question now in plain words. Do not write JSON or call a tool."

    /// The last paragraph of a reply has at least one letter or digit (not just "}" or an empty string).
    private static func hasReadableAnswer(_ reply: String) -> Bool {
        let last = reply.components(separatedBy: "\n\n").last ?? reply
        return last.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func statusText(_ phase: String) -> String {
        switch phase {
        case "preparing_workspace": return "Preparing…"
        case "preparing_context":   return "Reading the conversation…"
        case "starting_model":      return "Starting the model…"
        case "waiting_helpers":     return "Waiting for a teammate…"
        default:                    return "Thinking…"
        }
    }

    /// The Gateway's own question (an agent wants to run a command) on Coucou's approval screen.
    private func showGatewayApproval(_ ask: GatewayApproval, agent: String) {
        let state = AppState.shared
        state.pendingApproval = ApprovalInfo(sessionId: Self.gatewayPrefix + ask.id, tool: agent, command: ask.command,
                                             inputKey: "", pillId: "colony")
        state.isPinned = true
        SoundEngine.shared.play("approval")
        if state.mode == .expanded { state.view = .approval }
        else { NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval) }
    }

    private func clearGatewayApproval() {
        let state = AppState.shared
        guard state.pendingApproval?.sessionId.hasPrefix(Self.gatewayPrefix) == true else { return }
        state.pendingApproval = nil
        state.isPinned = false
        state.view = .prompt
    }

    /// Keeps a Gateway connection that listens for reminders going off; started once at launch.
    func watchReminders() {
        guard reminderTask == nil else { return }
        reminderTask = Task {
            while !Task.isCancelled {
                if Self.enabled {
                    await GatewayClient.shared.watchReminders { title, text, session in
                        Task { @MainActor in ColonyStore.shared.reminderFired(title: title, text: text, session: session) }
                    }
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func reminderFired(title: String, text: String, session: String) {
        let who = agents.first { session.hasPrefix("agent:\(workspaceId ?? "")-\($0.id):") }?.name
        let body = text.isEmpty ? title : text
        reminder = (who.map { "\($0): " } ?? "") + body
        let shown = reminder
        Task { try? await Task.sleep(nanoseconds: 30_000_000_000); if reminder == shown { reminder = nil } }   // clears itself
        SoundEngine.shared.play("finish")
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.prompt)
    }

    private static let gatewayPrefix = "gateway-"
    private static let askPrefix = "colony-"

    /// Colony's "may this agent run this?" goes through Coucou's own approval screen (the one Claude Code uses);
    /// the screen's Allow / Deny come back to `answerApproval`. `nil` takes a question we showed off the screen.
    private func showApproval(_ ask: ColonyApproval?, state: AppState) {
        let shown = state.pendingApproval?.sessionId.hasPrefix(Self.askPrefix) == true
        guard let ask else {
            if shown { state.pendingApproval = nil; state.isPinned = false; state.view = .prompt }
            return
        }
        if state.pendingApproval?.sessionId == Self.askPrefix + ask.id || (state.pendingApproval != nil && !shown) { return }
        state.pendingApproval = ApprovalInfo(sessionId: Self.askPrefix + ask.id, tool: ask.agent, command: ask.message,
                                             inputKey: "", pillId: "colony")
        state.isPinned = true
        SoundEngine.shared.play("approval")
        if state.mode == .expanded { state.view = .approval }
        else { NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval) }
    }

    /// The user pressed Allow / Deny on a Colony question.
    func answerApproval(allow: Bool) {
        let state = AppState.shared
        guard let id = state.pendingApproval?.sessionId else { return }
        if id.hasPrefix(Self.gatewayPrefix) {
            state.pendingApproval = nil
            state.isPinned = false
            state.view = .prompt
            Task { await GatewayClient.shared.resolveApproval(id: String(id.dropFirst(Self.gatewayPrefix.count)), allow: allow) }
            return
        }
        guard id.hasPrefix(Self.askPrefix) else { return }
        state.pendingApproval = nil
        state.isPinned = false
        state.view = .prompt
        Task { await ColonyService.answerApproval(id: String(id.dropFirst(Self.askPrefix.count)), approve: allow) }
    }

    func pollActivity(state: AppState) async {
        while !Task.isCancelled {
            guard let ws = workspaceId else { try? await Task.sleep(nanoseconds: 1_000_000_000); await reload(); continue }
            let (a, partial) = await ColonyService.activity(workspaceId: ws)
            if a != activity { activity = a }
            if nativeTurns == 0 {
                if partial != live.partial { live.partial = partial }
                if a.statusLine != live.status { live.status = a.statusLine }
            }
            showApproval(busyRooms.isEmpty ? nil : await ColonyService.approvals().first, state: state)
            let pose = ColonyService.botState(for: a)
            if state.stateOverride != pose { state.stateOverride = pose }
            // text arrives while a reply is being written: look more often then, rarely otherwise
            try? await Task.sleep(nanoseconds: busyRooms.isEmpty ? 1_000_000_000 : 350_000_000)
        }
        live.partial = nil
        live.status = nil
        showApproval(nil, state: state)
        state.stateOverride = nil
    }
}

extension ColonyMessage {
    /// Messages typed in the app and not yet confirmed by the server.
    var isLocalPending: Bool { id.hasPrefix("local-") }
}

/// Height of the island on the chat view. Colony's replies are long, so the island grows with the room
/// (up to 440 pt) instead of keeping Coucou's 240-300 pt, which cut answers off.
@MainActor
enum ChatHeight {
    static func current(coucouCount: Int) -> CGFloat {
        #if !APPSTORE
        // The Claude Code chat: grows with what is written (long answers open it up, short ones leave it), up to 560 pt.
        if ColonyStore.enabled, AppState.shared.claudeChat, AppState.shared.view == .prompt {
            return min(560, max(300, 190 + ClaudeSessionRunner.shared.chatContentHeight))
        }
        #endif
        if ColonyStore.enabled {
            return min(440, 300 + CGFloat(ColonyStore.shared.visible.count) * 36)
        }
        return min(300, 240 + CGFloat(coucouCount) * 40)
    }
}

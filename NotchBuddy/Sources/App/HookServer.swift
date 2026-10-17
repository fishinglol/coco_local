import Foundation
import Darwin
import AppKit
import SwiftUI
import CryptoKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String {
        #if APPSTORE
        // Container home root keeps path ≤ 103 bytes (sun_path limit on macOS is 104 incl. NUL)
        // /Users/louis/Library/Containers/fr.louisraille.Coucou/Data/nb.sock = 66 bytes ✓
        return NSHomeDirectory() + "/nb.sock"
        #else
        return supportDir.appendingPathComponent("nb.sock").path
        #endif
    }
    // hookScriptPath is only used by the non-App Store build.
    // App Store build derives the command from the panel-selected claudeURL in buildHooksData(claudeURL:).
    static var hookScriptPath: String { supportDir.appendingPathComponent("nb-hook").path }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private static let maxPayload = 1_048_576          // 1 MB — reject oversized messages
    private static let receiveTimeoutSeconds: Int = 5   // SO_RCVTIMEO on client sockets
    private static let maxConnections = 32              // concurrent connection ceiling

    private var serverFD: Int32 = -1
    private let connectionLock = NSLock()
    private var connectionCount = 0
    private var pendingApprovalFD: Int32 = -1         // held open while user decides
    private var approvalFDSource: (any DispatchSourceRead)? = nil  // monitors pendingApprovalFD
    private var pendingQuestionFD: Int32 = -1         // held open while user answers AskUserQuestion
    private var questionFDSource: (any DispatchSourceRead)? = nil  // monitors pendingQuestionFD

    /// True when a real nb-hook connection is holding the approval fd open.
    @MainActor var hasRealPendingApproval: Bool { pendingApprovalFD >= 0 }
    /// True when a real nb-hook connection is holding the question fd open.
    @MainActor var hasRealPendingQuestion: Bool { pendingQuestionFD >= 0 }
    private var questionPillId: String = ""           // pill that owns the pending question
    private var questionSessionId: String = ""        // sessionId for the pending question (recap tracking)
    private var focusBeforeQuestion: String? = nil    // saved focus to restore after question
    private var activeSessionId: String? = nil        // current Claude Code session
    private var focusBeforeApproval: String? = nil    // saved focus to restore after approval

    private init() {}

    // MARK: - Approval fd helpers

    @MainActor
    private func cancelApprovalFDSource() {
        approvalFDSource?.cancel()
        approvalFDSource = nil
    }

    /// Cancels the approval fd source (which closes the fd via its cancel handler), shows a
    /// 3-second note, clears approval state, then collapses the island.
    @MainActor
    private func dismissApprovalCard(note: String) {
        // cancelApprovalFDSource() triggers the cancel handler which closes the fd.
        // Never close the fd here directly — Apple requires it to happen in the cancel handler.
        cancelApprovalFDSource()
        pendingApprovalFD = -1
        let state = AppState.shared
        let pillId = state.pendingApproval?.pillId ?? "integration_claude"
        state.pendingApproval = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.noteMessage = note
        state.view = .note
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }

    // MARK: - Question fd helpers

    @MainActor
    private func cancelQuestionFDSource() {
        questionFDSource?.cancel()
        questionFDSource = nil
    }

    @MainActor
    private func dismissQuestionCard(note: String) {
        cancelQuestionFDSource()
        pendingQuestionFD = -1
        let state = AppState.shared
        let pillId = questionPillId
        state.pendingQuestion = nil
        state.isPinned = false
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        if let prev = focusBeforeQuestion {
            focusBeforeQuestion = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        if !note.isEmpty {
            state.noteMessage = note
            state.view = .note
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
        } else {
            state.view = state.tasks.isEmpty ? .empty : .overview
        }
    }

    /// Called by QuestionView. Sends answers JSON and cleans up.
    @MainActor
    func sendQuestionAnswers(_ answers: [String: Any]) {
        // Only intercept a demo question — real questions always have a live fd.
        if DemoEngine.shared.isActive, pendingQuestionFD < 0 {
            AppState.shared.pendingQuestion = nil
            AppState.shared.isPinned = false
            AppState.shared.view = AppState.shared.tasks.isEmpty ? .empty : .overview
            DemoEngine.shared.handleQuestionAnswered(answers: answers)
            return
        }
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        let sid = questionSessionId
        questionSessionId = ""
        if fd >= 0, let data = try? JSONSerialization.data(withJSONObject: ["permissionDecision": "answer", "answers": answers], options: .withoutEscapingSlashes),
           let json = String(data: data, encoding: .utf8) {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }
        if !sid.isEmpty { RecapStore.shared.recordQuestionAnswered(sessionId: sid) }
        dismissQuestionCard(note: "")
    }

    /// Called by QuestionView.onDisappear — card left screen without an explicit answer.
    /// Sends "ask" immediately to unblock nb-hook; does NOT navigate (view already changed).
    @MainActor
    func releaseQuestionFD() {
        guard pendingQuestionFD >= 0 else { return }
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        AppState.shared.pendingQuestion = nil
        Task.detached { [weak self] in
            self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
            DispatchQueue.main.async { source?.cancel() }
        }
    }

    /// Called by QuestionView "Reply in terminal" button.
    @MainActor
    func sendQuestionAsk() {
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        if fd >= 0 {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }
        dismissQuestionCard(note: "")
    }

    /// Returns the tool_input serialized as sorted-keys JSON, "" if absent or empty.
    /// Same computation used in processPermissionRequest and processEvent to match PostToolUse.
    private static func approvalInputKey(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    // MARK: - Start

    func start() {
        // Ensure support directory exists (mode 0700 — not world-readable)
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        #if !APPSTORE
        installHookScript()
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        // sun_path on macOS is 104 bytes including the NUL terminator → max 103 usable bytes
        let maxSunPathBytes = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard path.utf8.count <= maxSunPathBytes else {
            NSLog("HookServer: socket path too long (\(path.utf8.count) bytes, max \(maxSunPathBytes)): \(path)")
            return
        }
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        // Restrict socket to owner only
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            // Reject connections from other users (same-UID check)
            var euid: uid_t = 0
            var egid: gid_t = 0
            guard getpeereid(clientFD, &euid, &egid) == 0, euid == getuid() else {
                close(clientFD)
                continue
            }
            // Enforce concurrent connection ceiling
            connectionLock.lock()
            let count = connectionCount
            if count < Self.maxConnections { connectionCount += 1 }
            connectionLock.unlock()
            guard count < Self.maxConnections else {
                close(clientFD)
                continue
            }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        defer {
            connectionLock.lock(); connectionCount -= 1; connectionLock.unlock()
        }
        // 5-second receive timeout — unresponsive clients don't hold threads forever
        var tv = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
            if raw.count > Self.maxPayload { break }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let coucouKind = payload["coucou_kind"] as? String ?? ""

        // statusline payloads are handled separately — no session, no reveal, no sound
        if coucouKind == "statusline" {
            Task { @MainActor in self.processStatusLine(payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        // AskUserQuestion via --ask PreToolUse hook — hold fd open like PermissionRequest
        if coucouKind == "ask_user_question" {
            let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let parsed = AskQuestion.parse(toolInput: toolInput) {
                Task { @MainActor in self.processQuestionRequest(fd: fd, parsed: parsed, payload: payload) }
            } else {
                // Malformed payload — fall back: send ask so Claude Code re-asks in terminal
                sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // Claude Code events route to the permanent "integration_claude" task.
    // Events tagged with a valid coucou_agent route to a dynamic "integration_<agent>" task.
    // View switches only happen if VS Code (or the agent pill) is currently focused.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        // Determine which pill this event belongs to.
        // coucou_agent must be lowercase, digits and hyphens, ≤ 24 chars.
        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let validAgent = Self.validateAgent(rawAgent)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""

        // Cursor identified solely by its stable Electron bundle ID.
        // ToDesktop builds other apps too — do not match on "todesktop" alone.
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))
        let isClaudeDesktop = bundleId.lowercased() == "com.anthropic.claudefordesktop"

        // Routing:
        // • "codex" → agent_codex (GitHub build only: workspace pill, approvals in the notch)
        // • other valid coucou_agent → external pill (fire-and-forget, no approval card)
        // • Cursor bundle ID → agent_cursor
        // • VS Code → integration_claude
        #if !APPSTORE
        let isCodexEvent = rawAgent == "codex"
        #else
        let isCodexEvent = false
        #endif
        let agentId: String
        let isExternalAgent: Bool
        if isCodexEvent {
            agentId = "agent_codex"
            isExternalAgent = false
        } else if let agent = validAgent {
            agentId = "agent_\(agent)"
            isExternalAgent = true
        } else if isCursorEditor {
            agentId = "agent_cursor"
            isExternalAgent = false
        } else if isClaudeDesktop {
            agentId = "agent_claude"
            isExternalAgent = false
        } else if isVSCodeEditor {
            agentId = "integration_claude"
            isExternalAgent = false
        } else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == agentId
        #if !APPSTORE
        ClaudeSessionRunner.shared.note(pillId: agentId, sessionId: sessionId, cwd: cwd,
                                        transcript: payload["transcript_path"] as? String,
                                        permissionMode: payload["permission_mode"] as? String)
        #endif
        state.homeShowsTools = true     // Home opens on Tools, not on the Colony team
        // For sessions that carry no id, derive a unique key from pill + cwd so that
        // concurrent anonymous sessions are tracked independently in RecapStore.
        let recapSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(agentId)+\(cwd)"
            : sessionId

        #if PHONE_LINK
        // The iPhone's "last turn" (prompt, actions, diffs, answer).
        if !isExternalAgent { TurnRecorder.shared.record(event: name, payload: payload, pillId: agentId) }
        #endif

        // While a permission request is pending, dismiss when the resolving event arrives,
        // then continue normal processing. Only skip normal processing when unresolved.
        if let pending = state.pendingApproval, agentId == pending.pillId,
           pending.sessionId != "demo_session" {
            let handledNote: String
            switch pending.pillId {
            case "agent_cursor":  handledNote = "Handled in Cursor."
            case "agent_codex":   handledNote = "Handled in Codex."
            case "agent_copilot": handledNote = "Handled in Copilot CLI."
            case "agent_muse":    handledNote = "Handled in Muse Code."
            default:              handledNote = "Handled in VS Code."
            }
            var resolved = false
            switch name {
            case "PostToolUse", "PostToolUseFailure":
                // Only dismiss when this exact tool call finished — same session, tool and input.
                // Other parallel tools finishing must not close the card.
                if sessionId == pending.sessionId,
                   (payload["tool_name"] as? String ?? "") == pending.tool,
                   Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]) == pending.inputKey {
                    dismissApprovalCard(note: handledNote)
                    resolved = true
                }
            case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
                // Turn ended or session interrupted — the permission is moot.
                if sessionId == pending.sessionId {
                    dismissApprovalCard(note: handledNote)
                    resolved = true
                }
            default: break
            }
            if !resolved { return }
            // Approval dismissed — fall through so the resolving event updates state normally.
        }

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            nbLog("SessionStart \(isExternalAgent ? agentId : projectName) (\(sessionId.prefix(8)))")
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            activeSessionId = sessionId
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.updateTask(id: agentId, state: .thinking)
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: agentId, step: String(prompt.prefix(60)))
                #if !APPSTORE
                ClaudeSessionRunner.shared.record(sessionId: sessionId, isUser: true, text: prompt)
                #endif
            }
            RecapStore.shared.userPromptSubmit(sessionId: recapSessionId, pillId: agentId, project: projectName)
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            let tool = payload["tool_name"] as? String ?? "Tool"
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            RecapStore.shared.preToolUse(sessionId: recapSessionId, tool: tool)
            // AskUserQuestion is handled via the dedicated --ask hook.
            // Skip state/step update here to avoid flickering over the question card.
            guard tool != "AskUserQuestion" else { break }
            if isExternalAgent { upsertExternalAgent(id: agentId, name: validAgent!) } else { upsertWorkspaceTask(id: agentId, projectName: projectName, cwd: cwd) }
            state.updateTask(id: agentId, state: .working)
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = localizedStep(tool: tool, input: input)
            appendStep(id: agentId, step: step)
            nbLog("PreToolUse \(tool)")

        case "PostToolUse":
            state.updateTask(id: agentId, state: .working)
            // Live diff for Edit / MultiEdit / Write
            let diffTool = payload["tool_name"] as? String ?? ""
            let diffInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let diff = buildFileDiff(tool: diffTool, input: diffInput, pillId: agentId) {
                let idx = state.appendSessionDiff(diff, for: agentId)
                let step = String.makeDiffStep(filename: diff.name, added: diff.added, removed: diff.removed, diffId: idx)
                appendStep(id: agentId, step: step)
                RecapStore.shared.recordFileDiff(sessionId: recapSessionId, path: diff.name, added: diff.added, removed: diff.removed)
            }

        case "PostToolUseFailure":
            state.updateTask(id: agentId, state: .working)
            appendStep(id: agentId, step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: agentId, state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: agentId, state: .question)
                appendStep(id: agentId, step: message)
            }

        case "Stop":
            state.updateTask(id: agentId, state: .finished)
            let rawFinal = (payload["last_assistant_message"] as? String)
                ?? (payload["message"] as? String) ?? ""
            let finalText = DiffEngine.toOneLine(rawFinal)
            if !finalText.isEmpty {
                appendStep(id: agentId, step: finalText)
                if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
                    state.tasks[idx].finalLine = finalText
                }
            }
            RecapStore.shared.stop(sessionId: recapSessionId)
            #if !APPSTORE
            ClaudeSessionRunner.shared.record(sessionId: sessionId, isUser: false, text: rawFinal)
            #endif
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: agentId, badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                if isExternalAgent {
                    AppState.shared.removeTask(id: agentId)
                } else {
                    AppState.shared.updateTask(id: agentId, state: .idle)
                    self.clearPillBadge(id: agentId)
                }
            }

        case "StopFailure":
            RecapStore.shared.stop(sessionId: recapSessionId)
            state.updateTask(id: agentId, state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: agentId, badge: .error)
            }

        case "Interrupt":
            // Codex: user stopped the turn
            RecapStore.shared.stop(sessionId: recapSessionId)
            activeSessionId = nil
            state.updateTask(id: agentId, state: .idle)
            clearPillBadge(id: agentId)

        case "SessionEnd":
            activeSessionId = nil
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.clearSessionDiffs(for: agentId)
            state.removeTask(id: agentId)
            RecapStore.shared.sessionEnd(sessionId: recapSessionId)

        case "SubagentStart":
            appendStep(id: agentId, step: "+ subagent")

        case "SubagentStop":
            appendStep(id: agentId, step: "• subagent done")

        default:
            break
        }
    }

    // MARK: - Agent validation + dynamic pill

    /// Validates a coucou_agent name: lowercase, digits and hyphens, 1–24 chars.
    /// "claude" is reserved and rejected so it cannot impersonate the Claude Code pill.
    /// Returns the name unchanged if valid, nil otherwise.
    private static func validateAgent(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 24, raw != "claude" else { return nil }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)  // a-z
                  || (v >= 0x30 && v <= 0x39)   // 0-9
                  || v == 0x2D                   // -
            guard ok else { return nil }
        }
        return raw
    }

    /// Creates a dynamic pill for a third-party agent on first event, then no-ops.
    /// ID format: "agent_<name>" — never collides with "integration_*" pills.
    /// Inserted right after integration_claude so it appears in the visible prefix(4).
    @MainActor
    private func upsertExternalAgent(id: String, name: String) {
        let state = AppState.shared
        guard state.tasks.firstIndex(where: { $0.id == id }) == nil else { return }
        let color = IslandConst.colorForProject(name)
        let task = AgentTask(id: id, name: name, color: color, state: .idle, steps: [], source: .agent)
        if let claudeIdx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) {
            state.tasks.insert(task, at: claudeIdx + 1)
        } else {
            state.tasks.append(task)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .question, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            #if !APPSTORE
            // The Claude Code chat is open: the answer is already on screen, so no "finished" card over it.
            if view == .finished, state.view == .prompt, state.claudeChat { return }
            #endif
            // Approval and question always win; other alerts are blocked while a card is showing
            if view == .approval || view == .question {
                state.view = view
            } else if isAlert && state.pendingApproval == nil {
                state.view = view
            }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Status line (plan gauge)

    @MainActor
    private func processStatusLine(payload: [String: Any]) {
        if let usage = ClaudePlanGauge.parse(payload: payload) {
            AppState.shared.claudePlanUsage = usage
        }
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))
        let isClaudeDesktop = bundleId.lowercased() == "com.anthropic.claudefordesktop"

        // Codex, Copilot CLI and Muse Code get the same approval card as Claude Code / Cursor.
        // Other external agents (any other coucou_agent) answer immediately with "ask"
        // so the agent re-asks in its own terminal — they do not get a notch card.
        #if !APPSTORE
        let isCodexRequest   = rawAgent == "codex"
        let isCopilotRequest = rawAgent == "copilot"
        let isMuseRequest    = rawAgent == "muse"
        #else
        let isCodexRequest   = false
        let isCopilotRequest = false
        let isMuseRequest    = false
        #endif
        if !isCodexRequest && !isCopilotRequest && !isMuseRequest && Self.validateAgent(rawAgent) != nil {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        // Determine which workspace pill owns the request.
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCopilotRequest {
            pillId = "agent_copilot"
        } else if isMuseRequest {
            pillId = "agent_muse"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else if isClaudeDesktop {
            pillId = "agent_claude"
        } else {
            pillId = "integration_claude"
        }
        guard isCodexRequest || isCopilotRequest || isMuseRequest || isCursorEditor || isClaudeDesktop || isVSCodeEditor else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let inputKey = Self.approvalInputKey(toolInput)
        nbLog("PermissionRequest \(tool) [\(pillId)]")

        // AskUserQuestion is now handled via the dedicated --ask PreToolUse hook.
        // If it still arrives here as a PermissionRequest, reply "ask" so Claude Code
        // re-asks in the terminal — never show the question twice.
        if tool == "AskUserQuestion" {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let command = toolInput["command"] as? String ?? tool

        if pendingApprovalFD >= 0 {
            // Displace the previous request: write "ask" then cancel its source.
            // The cancel handler closes the old fd — never close it directly.
            let old = pendingApprovalFD
            let oldSource = approvalFDSource
            approvalFDSource = nil
            Task.detached { [weak self] in
                // "ask" → nb-hook outputs nothing → Claude Code re-asks
                self?.sendLine(fd: old, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { oldSource?.cancel() }
            }
        }
        pendingApprovalFD = fd
        activeSessionId = sessionId

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd)
        state.updateTask(id: pillId, state: .approval)
        state.pendingApproval = ApprovalInfo(sessionId: sessionId, tool: tool,
                                              command: command, inputKey: inputKey, pillId: pillId)
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond.
        // Save current focus so we can restore it when the card is dismissed.
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .approval)

        // Monitor fd: if the editor closes the connection (handled externally), dismiss the card.
        // The cancel handler closes the fd — never close it anywhere else.
        let capturedPillId = pillId
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingApprovalFD == fd else { return }
            let note: String
            switch capturedPillId {
            case "agent_cursor":  note = "Handled in Cursor."
            case "agent_codex":   note = "Handled in Codex."
            case "agent_copilot": note = "Handled in Copilot CLI."
            case "agent_muse":    note = "Handled in Muse Code."
            default:              note = "Handled in VS Code."
            }
            self.dismissApprovalCard(note: note)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        approvalFDSource = source

        // Safety timeout — show a note and cancel without sending a decision.
        // nb-hook reads EOF from the cancel handler's close and exits; Claude Code / Codex re-asks.
        // Copilot/Muse use 110s (their relay waits 118s but their hook timeout is 120s, leaving little margin).
        let waitTimeout: Double = (isCopilotRequest || isMuseRequest) ? 110 : 115
        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTimeout) { [weak self] in
            guard let self, self.pendingApprovalFD == captured else { return }
            let note: String
            switch capturedPillId {
            case "agent_cursor":  note = "Still waiting in Cursor."
            case "agent_codex":   note = "Still waiting in Codex."
            case "agent_copilot": note = "Still waiting in Copilot CLI."
            case "agent_muse":    note = "Still waiting in Muse Code."
            default:              note = "Still waiting in VS Code."
            }
            self.dismissApprovalCard(note: note)
        }
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        // Only intercept a demo card — a real card has a live fd (pendingApprovalFD >= 0).
        if DemoEngine.shared.isActive,
           AppState.shared.pendingApproval?.sessionId == "demo_session",
           pendingApprovalFD < 0 {
            let s = AppState.shared
            s.pendingApproval = nil
            s.isPinned = false
            s.view = s.tasks.isEmpty ? .empty : .overview
            DemoEngine.shared.handleApprovalDecision(decision)
            return
        }
        let fd = pendingApprovalFD
        pendingApprovalFD = -1
        // Capture source before nulling — we send the decision first, then cancel the source.
        // The cancel handler closes the fd; never close it directly.
        let source = approvalFDSource
        approvalFDSource = nil

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }

        if fd >= 0 {
            Task.detached { [weak self] in
                // Write decision while fd is still valid, then cancel source → cancel handler closes fd
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }

        let state = AppState.shared
        let pillId = state.pendingApproval?.pillId ?? "integration_claude"
        state.pendingApproval = nil
        state.isPinned = false
        RecapStore.shared.recordDecision(pillId: pillId, decision: decision)
        state.updateTask(id: pillId, state: .working)
        clearPillBadge(id: pillId)
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    // MARK: - Question request

    @MainActor
    private func processQuestionRequest(fd: Int32, parsed: AskQuestion, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let rawAgent    = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"]  as? String ?? ""
        let bundleId    = payload["bundle_id"]     as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))
        let isClaudeDesktop = bundleId.lowercased() == "com.anthropic.claudefordesktop"
        #if !APPSTORE
        let isCodexRequest = rawAgent == "codex"
        #else
        let isCodexRequest = false
        #endif
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else if isClaudeDesktop {
            pillId = "agent_claude"
        } else {
            pillId = "integration_claude"
        }
        guard isCodexRequest || isCursorEditor || isClaudeDesktop || isVSCodeEditor else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        // Displace any previous question waiting for an answer.
        if pendingQuestionFD >= 0 {
            let old = pendingQuestionFD
            let oldSrc = questionFDSource
            questionFDSource = nil
            Task.detached { [weak self] in
                self?.sendLine(fd: old, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { oldSrc?.cancel() }
            }
        }
        pendingQuestionFD = fd
        activeSessionId = sessionId
        questionPillId = pillId
        questionSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(pillId)+\(cwd)"
            : sessionId

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd)
        state.updateTask(id: pillId, state: .question)
        state.pendingQuestion = parsed
        state.isPinned = true
        SoundEngine.shared.play("approval")

        if focusBeforeQuestion == nil { focusBeforeQuestion = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .question)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingQuestionFD == fd else { return }
            self.dismissQuestionCard(note: "")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        questionFDSource = source

        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.pendingQuestionFD == captured else { return }
            // Send "ask" so nb-hook exits cleanly; Claude Code re-asks in terminal.
            let askFD = self.pendingQuestionFD
            self.pendingQuestionFD = -1
            let src = self.questionFDSource
            self.questionFDSource = nil
            Task.detached { [weak self] in
                self?.sendLine(fd: askFD, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { src?.cancel() }
            }
            self.dismissQuestionCard(note: "")
        }
    }

    /// Updates or transiently creates a workspace pill (VS Code or Cursor) task.
    /// If the task already exists (persistent), just updates name/cwd.
    /// If missing (transient), creates it and inserts after the main pill.
    @MainActor
    private func upsertWorkspaceTask(id: String, projectName: String, cwd: String = "") {
        let state = AppState.shared
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            state.tasks[idx].name = projectName
            if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
            return
        }
        // The Claude Code pill stays once its first session has been seen (declared active, so it is back after a restart;
        // the user can untick it in Settings → Active pills).
        if id == "agent_claude", !state.activeIntegrations.contains(id), state.activeIntegrations.count < 4 {
            state.activeIntegrations.insert(id)
        }
        // Transient: create and insert after the main pill
        let def = PillCatalog.definition(for: id)
        let color = def?.color ?? "#C0C4CC"
        let source = def?.source ?? .agent
        let task = AgentTask(id: id, name: projectName, color: color,
                             state: .idle, steps: [], source: source, isIntegration: true)
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.insert(task, at: 0)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - Localized step labels

    private func localizedStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":         String(localized: "step.runs",       defaultValue: "Runs"),
            "Read":         String(localized: "step.reads",      defaultValue: "Reads"),
            "Write":        String(localized: "step.writes",     defaultValue: "Writes"),
            "Edit":         String(localized: "step.edits",      defaultValue: "Edits"),
            "Glob":         String(localized: "step.searches",   defaultValue: "Searches"),
            "Grep":         String(localized: "step.searches",   defaultValue: "Searches"),
            "WebSearch":    String(localized: "step.web-search", defaultValue: "Searches the web"),
            "WebFetch":     String(localized: "step.fetches",    defaultValue: "Fetches"),
            "TodoWrite":    String(localized: "step.tasks",      defaultValue: "Tasks"),
            "Task":         String(localized: "step.agent",      defaultValue: "Agent"),
            "LS":           String(localized: "step.lists",      defaultValue: "Lists"),
            "MultiEdit":    String(localized: "step.edits",      defaultValue: "Edits"),
            "NotebookEdit": String(localized: "step.notebook",   defaultValue: "Notebook"),
            // Codex tools
            "apply_patch":  String(localized: "step.edits",     defaultValue: "Edits"),
            "update_plan":  String(localized: "step.tasks",     defaultValue: "Tasks"),
            "spawn_agent":  String(localized: "step.agent",     defaultValue: "Agent"),
        ]
        var label = labels[tool] ?? tool

        // Codex MCP tools arrive as mcp__server__tool — show "server · tool"
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let parts = rest.components(separatedBy: "__")
            label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : rest
        }

        // Bash: infer a more precise verb from the command
        if tool == "Bash", let cmd = input["command"] as? String {
            return "\(bashVerb(cmd)) · \(oneLine(cmd))"
        }

        // apply_patch: extract the first file name from the patch
        if tool == "apply_patch", let patch = input["command"] as? String {
            for line in patch.split(separator: "\n") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
                    if line.hasPrefix(prefix) {
                        let path = String(line.dropFirst(prefix.count))
                        return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
                    }
                }
            }
            return label
        }

        if let cmd = input["command"] as? String {
            return "\(label) · \(oneLine(cmd))"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(oneLine(query))"
        }
        return label
    }

    /// Infers a localized verb from a shell command's first word.
    private func bashVerb(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl": return String(localized: "step.reads",    defaultValue: "Reads")
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":    return String(localized: "step.searches", defaultValue: "Searches")
        default: break
        }
        let testRunners = ["pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test",
                           "xcodebuild test", "unittest"]
        if testRunners.contains(where: { command.contains($0) }) { return String(localized: "step.tests", defaultValue: "Tests") }
        return String(localized: "step.runs", defaultValue: "Runs")
    }

    // MARK: - Live diff helpers

    @MainActor
    private func buildFileDiff(tool: String, input: [String: Any], pillId: String) -> FileDiff? {
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String,
                  let path = input["file_path"] as? String,
                  !old.isEmpty || !new.isEmpty else { return nil }
            let d = DiffEngine.fromEdit(old: old, new: new, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        case "MultiEdit":
            guard let path = input["file_path"] as? String,
                  let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            var totalAdded = 0, totalRemoved = 0, allHunks: [DiffHunk] = [], anyLarge = false
            for edit in edits {
                guard let old = edit["old_string"] as? String,
                      let new = edit["new_string"] as? String else { continue }
                let d = DiffEngine.fromEdit(old: old, new: new, path: path)
                totalAdded += d.added; totalRemoved += d.removed
                allHunks.append(contentsOf: d.hunks); if d.tooLarge { anyLarge = true }
            }
            guard totalAdded > 0 || totalRemoved > 0 else { return nil }
            return FileDiff(path: path, added: totalAdded, removed: totalRemoved,
                            hunks: allHunks, tooLarge: anyLarge, isNewFile: false)

        case "Write":
            guard let path = input["file_path"] as? String,
                  let content = input["content"] as? String, !content.isEmpty else { return nil }
            let d = DiffEngine.fromNew(content: content, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        default:
            return nil
        }
    }

    /// Collapses whitespace so a multi-line command stays one ticker row.
    private func oneLine(_ text: String, limit: Int = 60) -> String {
        let collapsed = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
                            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        appendAppLog("nb.log", message)
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires NSOpenPanel to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        // nb-hook: shell wrapper (always exits 0, calls nb-hook.py via python3)
        let wrapperURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        // nb-hook.py: Python relay
        let pyURL = wrapperURL.deletingLastPathComponent().appendingPathComponent("nb-hook.py")
        try? nbHookPythonGitHub.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou hook that needs updating:
    /// either a PermissionRequest hook with timeout < 120s, or the AskUserQuestion
    /// PreToolUse matcher is missing (requires Claude Code 2.1.85+).
    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        // Track whether any Coucou hook is installed at all
        var hasCoucouHooks = false

        if let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] {
            for matcher in permReqHooks {
                if let hookList = matcher["hooks"] as? [[String: Any]] {
                    for hook in hookList {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("NotchBuddy") || cmd.contains("coucou") {
                            hasCoucouHooks = true
                            if let timeout = hook["timeout"] as? Int, timeout < 120 { return true }
                        }
                    }
                }
            }
        }

        // Check that the AskUserQuestion PreToolUse entry exists
        if hasCoucouHooks {
            let preToolHooks = hooks["PreToolUse"] as? [[String: Any]] ?? []
            let hasAskEntry = preToolHooks.contains { m in
                (m["matcher"] as? String) == "AskUserQuestion"
                && (m["hooks"] as? [[String: Any]])?.contains {
                    let cmd = $0["command"] as? String ?? ""
                    return cmd.contains("NotchBuddy") || cmd.contains("coucou")
                } ?? false
            }
            if !hasAskEntry { return true }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Backup first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #else
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("NotchBuddy") == true || ($0["command"] as? String)?.contains("coucou") == true } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("NotchBuddy") == true ||
                        ($0["command"] as? String)?.contains("coucou") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Claude plan status line installer

    private var statusLinePreviousURL: URL {
        Self.supportDir.appendingPathComponent("statusline-previous.json")
    }

    /// Returns true if our statusLine command is installed in ~/.claude/settings.json.
    static func statusLineInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sl = settings["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd.contains("nb-hook")
    }

    private var _pendingStatusLineData: Data?
    private var _pendingPreviousData: Data?
    private var _pendingDeletePrevious: Bool = false

    /// Returns a diff string (only the statusLine key: before → after) without writing anything.
    func previewStatusLine(install: Bool) throws -> String {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let d = try? Data(contentsOf: settingsURL),
           let parsed = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        let quotedPath = hookPath.replacingOccurrences(of: "\"", with: "\\\"")
        let quotedCmd = "\"\(quotedPath)\" --statusline"

        // Reset pending side-effects
        _pendingPreviousData = nil
        _pendingDeletePrevious = false

        let oldSL = settings["statusLine"] as? [String: Any]
        let newSL: [String: Any]?

        if install {
            // Check that Python 3 is available (requires Command Line Tools)
            let clCheck = Process()
            clCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            clCheck.arguments = ["-p"]
            clCheck.standardOutput = FileHandle.nullDevice
            clCheck.standardError = FileHandle.nullDevice
            try? clCheck.run()
            clCheck.waitUntilExit()
            if clCheck.terminationStatus != 0 {
                throw NSError(domain: "Coucou", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                  "Command Line Tools are required but not installed. Run: xcode-select --install"])
            }

            if let existing = oldSL,
               let cmd = existing["command"] as? String, !cmd.contains("nb-hook") {
                // Keep existing object but swap command; save old for later restoration
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
                _pendingPreviousData = try? JSONSerialization.data(withJSONObject: existing,
                                                                   options: [.prettyPrinted, .sortedKeys])
            } else if let existing = oldSL,
                      let cmd = existing["command"] as? String, cmd.contains("nb-hook") {
                // Already installed — rebuild to update path if needed, keep other fields
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
            } else {
                newSL = ["type": "command", "command": quotedCmd]
            }
        } else {
            // Uninstall: only if it's ours
            if let cur = oldSL, let cmd = cur["command"] as? String, cmd.contains("nb-hook") {
                if let prevData = try? Data(contentsOf: statusLinePreviousURL),
                   let prevObj = (try? JSONSerialization.jsonObject(with: prevData)) as? [String: Any] {
                    newSL = prevObj
                    _pendingDeletePrevious = true
                } else {
                    newSL = nil
                }
            } else {
                newSL = oldSL  // not ours — leave unchanged
            }
        }

        // Build the full settings.json with the new statusLine
        var newSettings = settings
        if let sl = newSL {
            newSettings["statusLine"] = sl
        } else {
            newSettings.removeValue(forKey: "statusLine")
        }
        let data = try JSONSerialization.data(withJSONObject: newSettings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _pendingStatusLineData = data

        // Build a compact diff: show only the statusLine key before → after
        func slJSON(_ val: [String: Any]?) throws -> String {
            guard let v = val else { return "(none)" }
            let d = try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
            return String(data: d, encoding: .utf8) ?? "(none)"
        }
        let before = try slJSON(oldSL)
        let after  = try slJSON(newSL)
        return "statusLine\nBefore:\n\(before)\n\nAfter:\n\(after)"
    }

    /// Writes settings.json and commits side effects (call after user confirms).
    func writeStatusLine() throws {
        guard let data = _pendingStatusLineData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        // Commit side effects only after successful write
        if let prevData = _pendingPreviousData {
            try? prevData.write(to: statusLinePreviousURL, options: .atomic)
        }
        if _pendingDeletePrevious {
            try? FileManager.default.removeItem(at: statusLinePreviousURL)
        }
        _pendingStatusLineData = nil
        _pendingPreviousData = nil
        _pendingDeletePrevious = false
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// Writes nb-hook script and updates settings.json in one shot.
    /// claudeURL must be a URL from NSOpenPanel (sandbox access is granted immediately — no security scope needed).
    func installAndWriteClaudeHooksAppStore(claudeURL: URL) throws {
        let data = try buildHooksData(claudeURL: claudeURL)

        // Write nb-hook (shell wrapper) + nb-hook.py (Python relay) into ~/.claude/coucou/
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let wrapperURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        let pyURL = coucouDir.appendingPathComponent("nb-hook.py")
        try nbHookPythonAppStore.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backupURL = claudeURL.appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try data.write(to: settingsURL, options: .atomic)
        UserDefaults.standard.set(true, forKey: "coucouHooksInstalled")
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("coucou") == true ||
                        ($0["command"] as? String)?.contains("NotchBuddy") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
        UserDefaults.standard.set(false, forKey: "coucouHooksInstalled")
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        // Derive hook path from the panel-selected claudeURL (real ~/.claude, not container)
        let hookPath = claudeURL.appendingPathComponent("coucou/nb-hook").path
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("coucou") == true ||
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif

    // MARK: - Gemini CLI and Antigravity hook installers  (#if !APPSTORE only)

    #if !APPSTORE
    private static var geminiSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
    }
    private static var agyHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/hooks.json")
    }

    // MARK: Installed-state detection

    static func geminiHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: geminiSettingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent gemini") { return true }
                    }
                }
                // Legacy flat entry
                if let cmd = group["command"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent gemini") { return true }
            }
        }
        return false
    }

    static func agyHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: agyHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let coucou = root["coucou"] else { return false }
        let json = (try? JSONSerialization.data(withJSONObject: coucou))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return json.contains("nb-hook")
    }

    // MARK: Gemini CLI – preview / write

    private var _pendingGeminiData: Data?
    private var _pendingGeminiFingerprint: String?

    func previewGeminiHooks(install: Bool) throws -> String {
        let url = Self.geminiSettingsURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Gemini CLI hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingGeminiFingerprint = sha256Hex(current)
        let newData = install ? try buildGeminiHooksData() : try withoutGeminiHooks()
        _pendingGeminiData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeGeminiHooks() throws {
        guard let data = _pendingGeminiData, let fp = _pendingGeminiFingerprint else { return }
        let url = Self.geminiSettingsURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/settings.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "settings.json")
        _pendingGeminiData = nil
        _pendingGeminiFingerprint = nil
    }

    private func buildGeminiHooksData() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.geminiSettingsURL,
                                                     label: "~/.gemini/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // (Gemini event key, normalized event name passed via argv, timeout in ms)
        let events: [(String, String, Int)] = [
            ("SessionStart", "SessionStart", 10000),
            ("SessionEnd",   "SessionEnd",   10000),
            ("BeforeTool",   "PreToolUse",   5000),
            ("AfterTool",    "PostToolUse",  5000),
            ("BeforeAgent",  "UserPromptSubmit", 5000),
            ("AfterAgent",   "Stop",         5000),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (geminiEvent, normalizedEvent, timeout) in events {
            if let raw = hooks[geminiEvent], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.gemini/settings.json: \"hooks\"[\"\(geminiEvent)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var groups = hooks[geminiEvent] as? [[String: Any]] ?? []
            // Remove legacy flat entries and groups whose inner hooks contain nb-hook
            groups = removeNbHookEntries(from: groups)
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent gemini \(normalizedEvent)",
                "timeout": timeout,
            ]
            groups.append(["matcher": "*", "hooks": [hookEntry]])
            hooks[geminiEvent] = groups
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutGeminiHooks() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.geminiSettingsURL,
                                                     label: "~/.gemini/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Antigravity – preview / write

    private var _pendingAgyData: Data?
    private var _pendingAgyFingerprint: String?

    func previewAgyHooks(install: Bool) throws -> String {
        let url = Self.agyHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Antigravity hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingAgyFingerprint = sha256Hex(current)
        let newData = install ? try buildAgyHooksData() : try withoutAgyHooks()
        _pendingAgyData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeAgyHooks() throws {
        guard let data = _pendingAgyData, let fp = _pendingAgyFingerprint else { return }
        let url = Self.agyHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.gemini/config/hooks.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "hooks.json")
        _pendingAgyData = nil
        _pendingAgyFingerprint = nil
    }

    private func buildAgyHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.agyHooksURL,
                                                 label: "~/.gemini/config/hooks.json")
        let base = hookBase()
        // PreToolUse / PostToolUse: tool-level hooks — use matcher group
        // PreInvocation / PostInvocation / Stop: lifecycle hooks — direct handler, no matcher
        var coucou: [String: Any] = [:]
        for event in ["PreToolUse", "PostToolUse"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [["matcher": "*", "hooks": [hook]]]
        }
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [hook]
        }
        root["coucou"] = coucou
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutAgyHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.agyHooksURL,
                                                 label: "~/.gemini/config/hooks.json")
        root.removeValue(forKey: "coucou")
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Shared helpers

    /// /bin/sh "<hookScriptPath>" — quoted for paths containing spaces (Application Support).
    private func hookBase() -> String {
        let path = Self.hookScriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/sh \"\(path)\""
    }

    /// Reads a JSON object from url.
    /// Absent file → empty dict. Present but invalid → throws with a user-facing message.
    private static func strictReadJSONObject(at url: URL, label: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(label) cannot be read — Coucou has not touched it."
            ])
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(label) is not valid JSON — Coucou has not touched it."
            ])
        }
        return obj
    }

    /// Backs up the existing file (throws on failure), creates parent dirs, then atomically writes.
    private func writeJSONFile(_ data: Data, to url: URL, suffix: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(suffix).bak-\(fmt.string(from: Date()))")
            do { try fm.copyItem(at: url, to: backupURL) }
            catch {
                throw NSError(domain: "Coucou", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Could not back up \(url.lastPathComponent): \(error.localizedDescription)"
                ])
            }
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Removes entries containing "nb-hook" from a Gemini-format groups array.
    /// Handles both new group format (matcher + hooks[]) and legacy flat format (command at top level).
    /// Returns the cleaned array; empty groups (after inner-hook removal) are dropped.
    private func removeNbHookEntries(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            // Legacy flat entry — command at group level
            if let cmd = group["command"] as? String, cmd.contains("nb-hook") { return nil }
            // Group format — filter inner hooks
            if var innerHooks = group["hooks"] as? [[String: Any]] {
                innerHooks.removeAll { ($0["command"] as? String)?.contains("nb-hook") == true }
                if innerHooks.isEmpty { return nil }
                var updated = group
                updated["hooks"] = innerHooks
                return updated
            }
            return group
        }
    }

    // MARK: - Codex hook installer  (#if !APPSTORE only)

    static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    /// True when ~/.codex/hooks.json already routes Codex events to Coucou's nb-hook.
    static func codexHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: codexHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent codex") { return true }
                    }
                }
            }
        }
        return false
    }

    private var _pendingCodexData: Data?
    private var _pendingCodexFingerprint: String?

    func previewCodexHooks(install: Bool) throws -> String {
        let url = Self.codexHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Codex hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingCodexFingerprint = sha256Hex(current)
        let newData = install ? try buildCodexHooksData() : try withoutCodexHooks()
        _pendingCodexData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeCodexHooks() throws {
        guard let data = _pendingCodexData, let fp = _pendingCodexFingerprint else { return }
        let url = Self.codexHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.codex/hooks.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "hooks.json")
        _pendingCodexData = nil
        _pendingCodexFingerprint = nil
    }

    private func buildCodexHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.codexHooksURL, label: "~/.codex/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.codex/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Events, timeouts in seconds (Codex format).
        // PermissionRequest uses 120s + a statusMessage shown in the Codex UI while waiting.
        let events: [(String, Int, String?)] = [
            ("SessionStart",    10,  nil),
            ("UserPromptSubmit", 10, nil),
            ("PreToolUse",      10,  nil),
            ("PermissionRequest", 120, "Waiting for your answer in the notch (Coucou)"),
            ("PostToolUse",     10,  nil),
            ("Stop",            10,  nil),
            ("SubagentStart",   10,  nil),
            ("SubagentStop",    10,  nil),
            ("Interrupt",        3,  nil),
            ("SessionEnd",       3,  nil),
        ]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout, statusMsg) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.codex/hooks.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Remove existing Coucou entries
            groups = removeNbHookEntries(from: groups)
            var hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent codex",
                "timeout": timeout,
            ]
            if let msg = statusMsg { hookEntry["statusMessage"] = msg }
            groups.append(["hooks": [hookEntry]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutCodexHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.codexHooksURL, label: "~/.codex/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.codex/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - GitHub Copilot CLI hook installer

    static var copilotHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/coucou.json")
    }

    /// True when ~/.copilot/hooks/coucou.json already routes Copilot events to Coucou's nb-hook.
    static func copilotHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: copilotHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if let cmd = entry["bash"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent copilot") { return true }
            }
        }
        return false
    }

    private var _pendingCopilotData: Data?
    private var _pendingCopilotFingerprint: String?

    func previewCopilotHooks(install: Bool) throws -> String {
        let url = Self.copilotHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Copilot hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingCopilotFingerprint = sha256Hex(current)
        if install {
            let newData = try buildCopilotHooksData()
            _pendingCopilotData = newData
            return String(data: newData, encoding: .utf8) ?? ""
        } else {
            _pendingCopilotData = nil  // nil = delete signal
            return "(will delete \(url.path))"
        }
    }

    func writeCopilotHooks() throws {
        guard let fp = _pendingCopilotFingerprint else { return }
        let url = Self.copilotHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json changed since preview. Refresh and try again."
            ])
        }
        if let data = _pendingCopilotData {
            try writeJSONFile(data, to: url, suffix: "coucou.json")
        } else {
            // Uninstall: delete the file entirely
            try FileManager.default.removeItem(at: url)
        }
        _pendingCopilotData = nil
        _pendingCopilotFingerprint = nil
    }

    private func buildCopilotHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.copilotHooksURL,
                                                  label: "~/.copilot/hooks/coucou.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Copilot CLI uses camelCase event names; each entry uses "bash" + "timeoutSec".
        // The event name is passed as a positional arg so the relay can fall back to it.
        // Copilot is fail-closed on permissionRequest — must always output valid JSON.
        let events: [(String, Int)] = [
            ("sessionStart",        10),
            ("userPromptSubmitted", 10),
            ("preToolUse",          10),
            ("permissionRequest",  120),
            ("postToolUse",         10),
            ("agentStop",           10),
            ("sessionEnd",           3),
            ("notification",        10),
        ]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { ($0["bash"] as? String)?.contains("nb-hook") == true }
            entries.append(["type": "command", "bash": "\(base) --agent copilot \(event)", "timeoutSec": timeout])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        root["version"] = 1
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutCopilotHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.copilotHooksURL,
                                                  label: "~/.copilot/hooks/coucou.json")
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if var entries = hooks[key] as? [[String: Any]] {
                    entries.removeAll { ($0["command"] as? String)?.contains("nb-hook") == true }
                    if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Muse Code hook installer

    static var museSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/muse/settings.json")
    }

    /// True when ~/.config/muse/settings.json already routes Muse events to Coucou's nb-hook.
    static func museHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: museSettingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for h in innerHooks {
                        if let cmd = h["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent muse") { return true }
                    }
                }
                if let cmd = group["command"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent muse") { return true }
            }
        }
        return false
    }

    private var _pendingMuseData: Data?
    private var _pendingMuseFingerprint: String?

    func previewMuseHooks(install: Bool) throws -> String {
        let url = Self.museSettingsURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Muse Code hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingMuseFingerprint = sha256Hex(current)
        let newData = install ? try buildMuseHooksData() : try withoutMuseHooks()
        _pendingMuseData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeMuseHooks() throws {
        guard let data = _pendingMuseData, let fp = _pendingMuseFingerprint else { return }
        let url = Self.museSettingsURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "settings.json")
        _pendingMuseData = nil
        _pendingMuseFingerprint = nil
    }

    private func buildMuseHooksData() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.museSettingsURL,
                                                      label: "~/.config/muse/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Muse uses PascalCase events. Timeouts in milliseconds (seconds × 1000).
        let events: [(String, Int)] = [
            ("SessionStart",      10),
            ("UserPromptSubmit",   5),
            ("PreToolUse",         5),
            ("PermissionRequest", 120),
            ("PostToolUse",        5),
            ("Stop",               5),
            ("SessionEnd",         3),
        ]
        let isNew = !FileManager.default.fileExists(atPath: Self.museSettingsURL.path)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeoutSec) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = removeNbHookEntries(from: groups)
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent muse \(event)",
                "timeout": timeoutSec * 1000,
            ]
            groups.append(["matcher": "*", "hooks": [hookEntry]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        if isNew { settings["schema_version"] = 1 }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutMuseHooks() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.museSettingsURL,
                                                      label: "~/.config/muse/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - OpenCode plugin installer

    private var _pendingOpenCodeContent: String?
    private var _pendingOpenCodeFingerprint: String?

    static var openCodePluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins/coucou.js")
    }

    static func openCodePluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: openCodePluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("opencode")
    }

    private func buildOpenCodePluginContent() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
// Coucou hook plugin for OpenCode — generated by Coucou.app
// Forwards every event to the Coucou notch (fire-and-forget, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';
const EVENT_MAP = {
  'session.created': 'SessionStart',
  'session.idle': 'Stop',
  'session.error': 'StopFailure',
  'session.deleted': 'SessionEnd',
  'permission.asked': 'PermissionRequest',
};

function forward(hook_event_name, payload) {
  const p = spawn('/bin/sh', [HOOK, '--agent', 'opencode'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  p.stdin.on('error', () => {});
  p.stdin.write(JSON.stringify({ hook_event_name, ...payload }) + '\\n');
  p.stdin.end();
  p.unref();
}

export const CoucouPlugin = async (_ctx) => ({
  event: async ({ event }) => {
    const hook_event_name = EVENT_MAP[event.type];
    if (!hook_event_name) return;
    const props = event.properties || {};
    const payload = {
      session_id: event.sessionID || event.session_id || props.sessionID || props.session_id || '',
      cwd: event.cwd || event.directory || props.cwd || props.directory || '',
    };
    if (typeof props.tool === 'string') payload.tool_name = props.tool;
    if (props.input != null) payload.tool_input = props.input;
    forward(hook_event_name, payload);
  },
  'tool.execute.before': async (input) => {
    forward('PreToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
      tool_input: input.input ?? null,
    });
  },
  'tool.execute.after': async (input, _output) => {
    forward('PostToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
    });
  },
});
"""
    }

    func previewOpenCodePlugin(install: Bool) throws -> String {
        let url = Self.openCodePluginURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install {
            guard exists else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No OpenCode plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: url)) ?? Data()
            _pendingOpenCodeFingerprint = sha256Hex(current)
            _pendingOpenCodeContent = nil
            return "(will delete \(url.path))"
        }
        let current = exists ? (try? Data(contentsOf: url)) ?? Data() : Data()
        _pendingOpenCodeFingerprint = sha256Hex(current)
        let content = buildOpenCodePluginContent()
        _pendingOpenCodeContent = content
        return content
    }

    func writeOpenCodePlugin() throws {
        guard let fp = _pendingOpenCodeFingerprint else { return }
        let url = Self.openCodePluginURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/opencode/plugins/coucou.js changed since preview. Refresh and try again."
            ])
        }
        guard let content = _pendingOpenCodeContent else {
            // Uninstall path: checked by removeOpenCodePlugin
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("coucou.js.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: backupURL)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingOpenCodeContent = nil
        _pendingOpenCodeFingerprint = nil
    }

    func removeOpenCodePlugin() throws {
        let url = Self.openCodePluginURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/opencode/plugins/coucou.js was not generated by Coucou — not deleting it."
            ])
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Amp plugin installer

    private var _pendingAmpContent: String?
    private var _pendingAmpFingerprint: String?

    static var ampPluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amp/plugins/coucou.ts")
    }

    static func ampPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: ampPluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("'amp'")
    }

    private func buildAmpPluginContent() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
// Coucou hook plugin for Amp — generated by Coucou.app
// Forwards every event to the Coucou notch (display only, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';

function forward(event_name: string, fields: Record<string, unknown>): void {
  const payload = JSON.stringify({ hook_event_name: event_name, ...fields });
  const p = spawn('/bin/sh', [HOOK, '--agent', 'amp'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  (p.stdin as import('node:stream').Writable).on('error', () => {});
  (p.stdin as import('node:stream').Writable).write(payload + '\\n');
  (p.stdin as import('node:stream').Writable).end();
  p.unref();
}

export default function (amp: any): void {
  amp.on('session.start', (e: any) => { forward('SessionStart',     { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.start',   (e: any) => { forward('UserPromptSubmit', { session_id: e.thread?.id ?? '' }); });
  amp.on('tool.call',     (e: any) => { try { forward('PreToolUse', { session_id: e.thread?.id ?? '', tool_name: typeof e.tool === 'string' ? e.tool : '' }); } finally { return { action: 'allow' }; } });
  amp.on('tool.result',   (e: any) => { forward('PostToolUse',      { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.end',     (e: any) => { forward('Stop',             { session_id: e.thread?.id ?? '' }); });
}
"""
    }

    func previewAmpPlugin(install: Bool) throws -> String {
        let url = Self.ampPluginURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install {
            guard exists else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No Amp plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: url)) ?? Data()
            _pendingAmpFingerprint = sha256Hex(current)
            _pendingAmpContent = nil
            return "(will delete \(url.path))"
        }
        let current = exists ? (try? Data(contentsOf: url)) ?? Data() : Data()
        _pendingAmpFingerprint = sha256Hex(current)
        let content = buildAmpPluginContent()
        _pendingAmpContent = content
        return content
    }

    func writeAmpPlugin() throws {
        guard let fp = _pendingAmpFingerprint else { return }
        let url = Self.ampPluginURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/amp/plugins/coucou.ts changed since preview. Refresh and try again."
            ])
        }
        guard let content = _pendingAmpContent else {
            // Uninstall path: checked by removeAmpPlugin
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("coucou.ts.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: backupURL)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingAmpContent = nil
        _pendingAmpFingerprint = nil
    }

    func removeAmpPlugin() throws {
        let url = Self.ampPluginURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/amp/plugins/coucou.ts was not generated by Coucou — not deleting it."
            ])
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: SHA-256 fingerprint

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook shell wrapper (same for both GitHub and App Store)
// Invoked by Claude Code via /bin/sh or directly via shebang.
// Always exits 0 — never blocks Claude Code.
// Checks xcode-select before running python3 to avoid triggering the
// "install developer tools" dialog on machines without Xcode CLI tools.

private let nbHookShellWrapper = """
#!/bin/sh
# Coucou hook relay — always exits 0, never blocks Claude Code
HOOK_DIR="$(dirname "$0")"
out=""
if xcode-select -p >/dev/null 2>&1; then
    out=$(/usr/bin/python3 "$HOOK_DIR/nb-hook.py" "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        out=""
    fi
fi
if [ -n "$out" ]; then
    printf '%s\\n' "$out"
else
    # Copilot is fail-closed — must always output valid JSON even when python3 is absent or crashes.
    _cop=0; _perm=0
    for _a in "$@"; do
        case "$_a" in
            copilot) _cop=1 ;;
            permissionRequest|PermissionRequest) _perm=1 ;;
        esac
    done
    if [ "$_cop" -eq 1 ]; then
        if [ "$_perm" -eq 1 ]; then
            printf '{"permissionDecision":"ask"}\\n'
        else
            printf '{}\\n'
        fi
    fi
fi
exit 0
"""

// MARK: - nb-hook Python relay (GitHub / non-sandboxed version)

private let nbHookPythonGitHub = """
#!/usr/bin/env python3
# nb-hook.py — Coucou hook relay for Claude Code and third-party agents (GitHub version)
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    socket_path = os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )

    # --statusline mode: relay rate_limits to Coucou, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'coucou_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(socket_path)
            s.sendall((json.dumps(relay) + '\\n').encode())
            s.close()
        except Exception:
            pass
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        if os.path.exists(prev_file):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['coucou_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'answer':
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code asks in terminal
        except Exception:
            pass
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with coucou_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('coucou_agent', agent)

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    # socket_path is already defined above

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision in ('allow', 'always'):
                    # Copilot/Muse use {"permissionDecision":"allow"} directly
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'allow'}
                    elif decision == 'always' and agent != 'codex':
                        # Let Claude Code persist the rule via updatedPermissions
                        suggestions = payload.get('permission_suggestions', [])
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    else:
                        # Claude Code / Codex plain allow
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'deny'}
                    else:
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'answer':
                    # AskUserQuestion answered from the notch
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\\n')
            sys.stdout.flush()
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Gemini CLI, Antigravity, Muse Code and Copilot CLI expect {} on stdout (empty = no decision)
    # Antigravity fails closed on PreToolUse: `decision` is required there, so {} blocks every tool call.
    # "ask" = Antigravity's own prompt (respects Always Allow); Coucou never auto-approves.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)
"""

// MARK: - nb-hook Python relay (App Store — socket in sandboxed container)

private let nbHookPythonAppStore = """
#!/usr/bin/env python3
# nb-hook.py — Coucou (App Store) hook relay for Claude Code and third-party agents
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock'
    )

    # --statusline mode: relay rate_limits to Coucou, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'coucou_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(socket_path)
            s.sendall((json.dumps(relay) + '\\n').encode())
            s.close()
        except Exception:
            pass
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        if os.path.exists(prev_file):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['coucou_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'answer':
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code asks in terminal
        except Exception:
            pass
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with coucou_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('coucou_agent', agent)

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    # socket_path is already defined above

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision in ('allow', 'always'):
                    # Copilot/Muse use {"permissionDecision":"allow"} directly
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'allow'}
                    elif decision == 'always' and agent != 'codex':
                        # Let Claude Code persist the rule via updatedPermissions
                        suggestions = payload.get('permission_suggestions', [])
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    else:
                        # Claude Code / Codex plain allow
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'deny'}
                    else:
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'answer':
                    # AskUserQuestion answered from the notch
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\\n')
            sys.stdout.flush()
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Gemini CLI, Antigravity, Muse Code and Copilot CLI expect {} on stdout (empty = no decision)
    # Antigravity fails closed on PreToolUse: `decision` is required there, so {} blocks every tool call.
    # "ask" = Antigravity's own prompt (respects Always Allow); Coucou never auto-approves.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)
"""

#if !APPSTORE
/// What the session's last assistant turn says about itself: model, reasoning effort, tokens in context.
struct ClaudeMeta: Equatable {
    let model: String      // "Sonnet 5.5"
    let effort: String?    // "Medium"
    let tokens: Int
    var modelId = ""       // "claude-sonnet-5-5-…": the window belongs to the model, not to one session
    var windowSize: Int? = nil

    /// The model's window as learned from the transcripts (`ClaudeSessionRunner.windowFor`); 200k until one of its
    /// sessions has held more, then 1M.
    var window: Int { windowSize ?? (tokens > 200_000 ? 1_000_000 : 200_000) }
    var fraction: Double { min(1, Double(tokens) / Double(window)) }
    var label: String { "\(Int((fraction * 100).rounded())) %" }
    var detail: String { "\(tokens.formatted()) of \(window.formatted()) tokens" }

    /// "claude-sonnet-5-5-20260101" → "Sonnet 5.5"
    static func prettyModel(_ id: String) -> String {
        var parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        parts.removeAll { $0.count >= 8 && Int($0) != nil }          // a date suffix
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        return name.capitalized + (version.isEmpty ? "" : " " + version)
    }
}

struct ClaudeTool: Equatable {
    let name: String
    let detail: String       // the command, the file, the pattern…
    var output: String = ""  // first lines of the result
    var failed = false
}

/// A Claude Code session seen on one of the pills (the chat's session picker lists these).
struct ClaudeSessionRef: Identifiable, Equatable {
    var id: String { sessionId }
    let pillId: String
    let sessionId: String
    let cwd: String
    var seen: Date
    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var source: String {
        switch pillId {
        case "agent_claude": return "Claude"
        case "agent_cursor": return "Cursor"
        default:             return "VS Code"
        }
    }
}

struct ClaudeLine: Identifiable, Equatable {
    let id: Int          // position in the transcript: stable between reloads, so the list keeps its scroll position
    let isUser: Bool
    let text: String
    var tool: ClaudeTool? = nil
    var at: Date? = nil      // when the transcript row was written (for "Worked for Ns")
}

// MARK: - Talking into a Claude Code session from the notch

/// Remembers the Claude Code session last seen on each pill (from the hooks) and continues it in the background:
/// `claude -p <text> --resume <session id>`, in the session's own folder. Hooks keep working, so the notch, and
/// any permission request, follow the run like any other turn. Used by the Claude Code card and the iPhone link.
/// GitHub build only: the App Store build is sandboxed and can't start `claude`.
@MainActor
final class ClaudeSessionRunner: ObservableObject {
    static let shared = ClaudeSessionRunner()
    private var sessions: [String: (sessionId: String, cwd: String)] = [:]
    @Published private var running: [String: Process] = [:]   // by session id
    /// The session the notch chat talks to: the latest one a hook reported on a Claude Code pill.
    @Published private(set) var current: (pillId: String, sessionId: String, cwd: String)?
    /// What was said in each session, from the hooks (prompt and last answer), so typed and sent-from-here turns both show.
    @Published private(set) var lines: [String: [ClaudeLine]] = [:]
    @Published private(set) var meta: [String: ClaudeMeta] = [:]
    /// `lines` as the Colony chat's messages, rebuilt only when `lines` changes.
    @Published private(set) var thread: [String: [ColonyMessage]] = [:]

    private var transcripts: [String: String] = [:]   // session id → its .jsonl
    @Published private(set) var recent: [ClaudeSessionRef] = []
    /// nil = the chat follows the latest session; else the session it stays on.
    @Published private(set) var pinnedId: String?

    /// The picker: nil follows the latest session again, a session pins the chat to it.
    func select(_ ref: ClaudeSessionRef?) {
        pinnedId = ref?.sessionId
        if let r = ref ?? recent.first { current = (r.pillId, r.sessionId, r.cwd) }
    }

    /// Re-reads the current session's transcript (the whole conversation, whoever typed it) into `lines`.
    private var lastStat: [String: String] = [:]   // transcript path → "size|mtime" of the last read

    // MARK: Context window
    // A transcript does not say how big the model's window is. It is the model's, not the session's, so: the most
    // context any session of that model has held (kept across launches, seeded once from the newest transcripts).
    // Past 200k it is the 1M window; below that, 200k.
    private static let maxKey = "claudeModelMaxContext"
    private var maxSeen: [String: Int] = (UserDefaults.standard.dictionary(forKey: ClaudeSessionRunner.maxKey) as? [String: Int]) ?? [:]
    private var seeded: Set<String> = []

    func windowFor(modelId: String, tokens: Int) -> Int {
        if tokens > (maxSeen[modelId] ?? 0) {
            maxSeen[modelId] = tokens
            UserDefaults.standard.set(maxSeen, forKey: Self.maxKey)
        }
        if !seeded.contains(modelId) {
            seeded.insert(modelId)
            Task { [weak self] in
                let best = await Task.detached { Self.biggestContext(of: modelId) }.value
                guard let self, best > (self.maxSeen[modelId] ?? 0) else { return }
                self.maxSeen[modelId] = best
                UserDefaults.standard.set(self.maxSeen, forKey: Self.maxKey)
                self.lastStat = [:]     // re-read, so the meter picks the new window up
            }
        }
        return (maxSeen[modelId] ?? 0) > 200_000 ? 1_000_000 : 200_000
    }

    /// The biggest context a reply of `modelId` shows at the end of the 40 newest transcripts.
    nonisolated private static func biggestContext(of modelId: String) -> Int {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var files: [(URL, Date)] = []
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.pathExtension == "jsonl" {
                files.append((f, (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            }
        }
        var best = 0
        for (f, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(40) {
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
            guard let data = try? h.readToEnd() else { continue }
            for row in data.split(separator: UInt8(ascii: "\n")) where row.count > 20 {
                guard let o = try? JSONSerialization.jsonObject(with: Data(row)) as? [String: Any],
                      let msg = o["message"] as? [String: Any], msg["model"] as? String == modelId,
                      let u = msg["usage"] as? [String: Any] else { continue }
                let n = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + (u[$1] as? Int ?? 0) }
                best = max(best, n)
            }
        }
        return best
    }

    func reload() async {
        guard let cur = current else { return }
        let path = transcripts[cur.sessionId] ?? Self.transcriptGuess(cwd: cur.cwd, sessionId: cur.sessionId)
        // Nothing new in the file: no parse, and above all nothing published (every publish redraws the chat mid-scroll).
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let stat = "\(attrs?[.size] as? UInt64 ?? 0)|\(attrs?[.modificationDate] as? Date ?? .distantPast)"
        if lastStat[path] == stat, lines[cur.sessionId] != nil { return }
        lastStat[path] = stat
        let (parsed, info) = await Task.detached { Self.parseTranscript(path: path) }.value
        if !parsed.isEmpty, lines[cur.sessionId] != parsed {   // empty = unreadable: keep what the hooks gave
            lines[cur.sessionId] = parsed
            thread[cur.sessionId] = ClaudeCodeChatView.buildThread(parsed)
        }
        if var info {
            info.windowSize = windowFor(modelId: info.modelId, tokens: info.tokens)
            if meta[cur.sessionId] != info { meta[cur.sessionId] = info }
        }
    }

    /// ~/.claude/projects/<folder with every non-alphanumeric turned into "-">/<session>.jsonl
    nonisolated private static func transcriptGuess(cwd: String, sessionId: String) -> String {
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(folder)/\(sessionId).jsonl").path
    }

    /// The last ~4 MB of the file: user prompts and assistant text only (no tools, thinking, tool results).
    nonisolated private static func parseTranscript(path: String) -> ([ClaudeLine], ClaudeMeta?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return ([], nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > 4_000_000 ? size - 4_000_000 : 0
        try? h.seek(toOffset: from)
        guard let data = try? h.readToEnd() else { return ([], nil) }
        var rows = data.split(separator: UInt8(ascii: "\n"))
        if from > 0, !rows.isEmpty { rows.removeFirst() }          // cut in the middle of a line
        var out: [ClaudeLine] = []
        var toolAt: [String: Int] = [:]       // tool_use id → index in `out`
        var meta: ClaudeMeta?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for row in rows {
            guard let o = try? JSONSerialization.jsonObject(with: Data(row)) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { continue }
            if type == "assistant", let usage = msg["usage"] as? [String: Any], let model = msg["model"] as? String,
               !model.hasPrefix("<") {
                let n = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
                let effort = (o["effort"] as? String).map { $0.capitalized }
                if n > 0 { meta = ClaudeMeta(model: ClaudeMeta.prettyModel(model), effort: effort, tokens: n, modelId: model) }
            }
            let at = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
            var texts: [String] = []
            if let s = msg["content"] as? String { texts = [s] }
            else if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String { texts.append(t) }
                    case "tool_use":
                        let input = b["input"] as? [String: Any] ?? [:]
                        let detail = (input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["url"]
                                      ?? input["path"] ?? input["description"]) as? String
                            ?? String(String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), encoding: .utf8)?.prefix(160) ?? "")
                        if let id = b["id"] as? String { toolAt[id] = out.count }
                        out.append(ClaudeLine(id: out.count, isUser: false, text: "",
                                              tool: ClaudeTool(name: b["name"] as? String ?? "Tool", detail: detail), at: at))
                    case "tool_result":
                        guard let id = b["tool_use_id"] as? String, let i = toolAt[id] else { continue }
                        var res = ""
                        if let s = b["content"] as? String { res = s }
                        else if let arr = b["content"] as? [[String: Any]] { res = arr.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                        out[i].tool?.output = res.components(separatedBy: "\n").prefix(3).joined(separator: "\n")
                        out[i].tool?.failed = b["is_error"] as? Bool == true
                    default: break
                    }
                }
            }
            for t in texts {
                var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if type == "user", let name = Self.tag("command-name", in: s) {       // "/ponytail start" typed in the window
                    s = (name + " " + (Self.tag("command-args", in: s) ?? "")).trimmingCharacters(in: .whitespaces)
                }
                // What the window adds around a message (reminders, command output, hook notes) is not something the user said;
                // a message that merely starts with "<" (pasted HTML, a comment) is.
                let system = ["<system-reminder", "<local-command", "<command-", "<bash-", "<task-notification",
                              "<user-prompt-submit-hook", "<ide_", "<synthetic"]
                if s.isEmpty || s.hasPrefix("[Request interrupted") || system.contains(where: { s.hasPrefix($0) }) { continue }
                if type == "assistant", s.hasPrefix("<") { continue }
                out.append(ClaudeLine(id: out.count, isUser: type == "user", text: s, at: at))
            }
        }
        return (Array(out.suffix(600)), meta)
    }

    nonisolated private static func tag(_ name: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBusy: Bool { current.map { running[$0.sessionId] != nil } ?? false }

    /// The newest answer in the shown session, on one line (the finished card shows it).
    var lastReply: String? {
        guard let cur = current, let l = lines[cur.sessionId]?.last(where: { !$0.isUser && $0.tool == nil }) else { return nil }
        let t = DiffEngine.toOneLine(l.text)
        return t.isEmpty ? nil : t
    }

    /// Opens the Claude chat page: the transcript is read first, so the island grows once, straight to its size.
    func openChat() async {
        await reload()
        let state = AppState.shared
        state.claudeChat = true
        withAnimation(.easeInOut(duration: 0.2)) { state.view = .prompt }
    }

    /// The stop button: ends the `claude -p` run this app started for the shown session (its termination handler clears `running`).
    func stop() { current.flatMap { running[$0.sessionId] }?.terminate() }

    /// A rough height of the current session's feed (the last 120 lines): how many rows each message wraps to,
    /// plus one row for a run of tool steps. The island uses it to open as far as the conversation needs.
    var chatContentHeight: CGFloat {
        guard let cur = current, let ls = lines[cur.sessionId] else { return 0 }
        var h: CGFloat = 0
        var inRun = false
        for l in ls.suffix(120) {
            if l.tool != nil {
                if !inRun { h += 24; inRun = true }
                continue
            }
            inRun = false
            let perRow = l.isUser ? 58 : 74           // characters per wrapped row at the chat's width
            let rows = l.text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + perRow - 1) / perRow) }
            h += CGFloat(rows) * 17 + (l.isUser ? 18 : 6) + 6
        }
        return h
    }

    private var modes: [String: String] = [:]   // session id → the permission mode the window runs it in

    func note(pillId: String, sessionId: String, cwd: String, transcript: String? = nil, permissionMode: String? = nil) {
        guard !sessionId.isEmpty, sessionId != "unknown", !cwd.isEmpty else { return }
        if let m = permissionMode, !m.isEmpty { modes[sessionId] = m }
        sessions[pillId] = (sessionId, cwd)
        if let t = transcript, !t.isEmpty { transcripts[sessionId] = t }
        guard ["integration_claude", "agent_claude", "agent_cursor"].contains(pillId) else { return }
        // The picker's list: newest first, one entry per session. Only publish when the order or the list changes.
        if let i = recent.firstIndex(where: { $0.sessionId == sessionId }) {
            if i != 0 || recent[0].cwd != cwd {
                recent.remove(at: i)
                recent.insert(ClaudeSessionRef(pillId: pillId, sessionId: sessionId, cwd: cwd, seen: Date()), at: 0)
            }
        } else {
            recent.insert(ClaudeSessionRef(pillId: pillId, sessionId: sessionId, cwd: cwd, seen: Date()), at: 0)
            if recent.count > 8 { recent.removeLast() }
        }
        // Following the latest (default) or pinned to one session: a pinned chat does not jump on other sessions' events.
        if pinnedId == nil || pinnedId == sessionId,
           current?.pillId != pillId || current?.sessionId != sessionId || current?.cwd != cwd {
            current = (pillId, sessionId, cwd)
        }
    }

    func record(sessionId: String, isUser: Bool, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, sessionId != "unknown", !t.isEmpty else { return }
        lines[sessionId, default: []].append(ClaudeLine(id: (lines[sessionId]?.last?.id ?? -1) + 1, isUser: isUser, text: t))
        if lines[sessionId]!.count > 600 { lines[sessionId]!.removeFirst() }
        thread[sessionId] = ClaudeCodeChatView.buildThread(lines[sessionId]!)
    }

    /// Starts the instruction; returns nil when it started, else why not (shown under the field).
    func send(_ text: String, pillId: String) -> String? {
        guard ["integration_claude", "agent_claude", "agent_cursor"].contains(pillId) else { return "\(pillId) can't take instructions" }
        guard !text.isEmpty, text.count <= 8000 else { return "empty or too long" }
        // The session the chat shows (it may be an older one on the same pill), else the latest seen there.
        let target: (sessionId: String, cwd: String)? = current?.pillId == pillId
            ? (current!.sessionId, current!.cwd) : sessions[pillId]
        guard let session = target else { return "no Claude Code session seen yet: send one message in its window first" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "the session's folder is gone"
        }
        guard running[session.sessionId] == nil else { return "an instruction is already running for this session" }
        guard let claude = Self.claudeExecutable() else {
            return "can't find the claude command (looked in ~/.claude/local, Homebrew, /usr/local/bin, ~/.npm-global/bin, nvm)"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", text, "--resume", session.sessionId]
        // Same permission mode as the window runs it in (Coucou is a mirror, not a stricter second user).
        if let m = modes[session.sessionId] {
            let mapped = m == "default" ? "manual" : m
            if ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"].contains(mapped) {
                process.arguments?.append(contentsOf: ["--permission-mode", mapped])
            }
        }
        process.currentDirectoryURL = URL(fileURLWithPath: session.cwd)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [URL(fileURLWithPath: claude).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin", env["PATH"] ?? ""].joined(separator: ":")
        // The hooks route events by editor: keep them on the same pill.
        switch pillId {
        case "agent_cursor": env["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
        case "agent_claude": env["__CFBundleIdentifier"] = "com.anthropic.claudefordesktop"
        default:             env["TERM_PROGRAM"] = "vscode"
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        // Output goes to a file (a pipe could fill up and stall claude).
        let logURL = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/NotchBuddy/instruction-last.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        let sid = session.sessionId
        let runner = self
        process.terminationHandler = { _ in
            try? output?.close()
            Task { @MainActor in runner.running[sid] = nil }
        }
        do { try process.run() } catch { return "couldn't start claude: \(error.localizedDescription)" }
        running[sid] = process
        return nil
    }

    /// Where `claude` usually lives; the app doesn't get the shell's PATH.
    static func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        // npm -g under nvm: ~/.nvm/versions/node/<version>/bin/claude
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        return versions.sorted(by: >).map { "\(nvm)/\($0)/bin/claude" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif

import SwiftUI

/// Settings → Colony: pick a workspace, then edit its agents (name, model, when to answer, persona, tools).
/// Same fields as the agent editor in Colony's web UI; saved through Colony's own API.
struct ColonySettingsView: View {
    @ObservedObject private var store = ColonyStore.shared
    @AppStorage("colonyChatEnabled") private var chatOn = true
    @AppStorage("colonyBaseURL") private var baseURL = "http://127.0.0.1:8765"

    private enum Tab: String, CaseIterable { case profile = "Profile", personality = "Personality", tools = "Tools", skills = "Skills", memory = "Memory" }

    @State private var roles: [[String: Any]] = []
    @State private var selectedId: String?
    @State private var draft: [String: Any] = [:]
    @State private var tab: Tab = .profile
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmDelete = false
    @State private var files: [String: Any]?
    @State private var filesLoading = false
    @State private var skills: [ColonyService.Skill]?
    @State private var gatewayStatus = "Not tested"
    @State private var githubURL = ""
    @State private var downloading = false
    @State private var composio: Bool?
    @State private var newApp = ""
    @State private var showAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Use Colony for chat and Home", isOn: $chatOn)
            HStack {
                Text("Server").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("http://127.0.0.1:8765", text: $baseURL).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("Reconnect") { Task { await store.reload(); await loadRoles() } }
            }
            HStack {
                Text("Gateway").font(.system(size: 12)).foregroundColor(.secondary)
                Text(gatewayStatus).font(.system(size: 12)).foregroundColor(.secondary)
                Button("Test connection") { checkGateway() }
            }
            Divider()
            if store.offline {
                Text("Colony isn't running. Start it with the `colony` command, then reopen this page.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                workspaceRow
                Divider()
                agentChips
                if selectedId != nil { editor }
            }
        }
        .task { await store.reload(); await store.loadModelsIfNeeded(); await loadRoles() }
        .confirmationDialog("Delete this agent?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        }
    }

    // MARK: Workspace + agent list

    private var workspaceRow: some View {
        HStack {
            Text("Workspace").font(.system(size: 12)).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { store.workspaceId ?? "" },
                set: { id in store.selectWorkspace(id); Task { try? await Task.sleep(nanoseconds: 400_000_000); await loadRoles() } }
            )) {
                ForEach(store.workspaces, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(maxWidth: 240)
            Spacer()
        }
    }

    private var agentChips: some View {
        HStack(spacing: 8) {
            ForEach(Array(roles.enumerated()), id: \.offset) { _, r in
                let id = r["id"] as? String ?? ""
                Button { select(id) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: ColonyService.color(forAgent: id))).frame(width: 8, height: 8)
                        Text(r["name"] as? String ?? id)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(selectedId == id ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if roles.count < 8 {
                Button { addAgent() } label: { Label("New agent", systemImage: "plus").font(.system(size: 12)) }
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)

            switch tab {
            case .profile:     profileTab
            case .personality: personalityTab
            case .tools:       toolsTab
            case .skills:      skillsTab
            case .memory:      memoryTab
            }

            if tab != .memory, tab != .skills, let m = message {
                Text(m).font(.system(size: 12)).foregroundColor(messageIsError ? .red : .secondary)
            }
            if tab != .memory, tab != .skills {
                HStack {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .disabled(roles.count <= 1)
                    Spacer()
                    Button("Cancel") { if let id = selectedId { select(id) } }
                    Button("Save") { save() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: tab) { t in
            if t == .memory { Task { await loadFiles() } }
            if t == .skills { Task { await loadSkills() } }
            if t == .tools { Task { composio = await ColonyService.composioConnected() } }
        }
        .onChange(of: selectedId) { _ in
            files = nil; skills = nil
            if tab == .memory { Task { await loadFiles() } }
            if tab == .skills { Task { await loadSkills() } }
        }
    }

    // MARK: Memory (read only: what OpenClaw keeps for this agent)

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if filesLoading && files == nil {
                Text("Loading…").font(.system(size: 12)).foregroundColor(.secondary)
            } else if let f = files {
                if f["started"] as? Bool == false {
                    Text("This agent hasn't answered yet, so it has no files of its own. Its persona is shown from the editor.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text("Shared with the whole team").font(.system(size: 12, weight: .semibold))
                fileBlock("USER.md · about you", f["user"] as? String)
                fileBlock("MEMORY.md · long-term memory", f["memory"] as? String)
                ForEach(Array((f["daily"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, d in
                    fileBlock("memory/\(d["date"] as? String ?? "").md", d["content"] as? String)
                }
                Text("This agent only").font(.system(size: 12, weight: .semibold)).padding(.top, 6)
                fileBlock("SOUL.md · persona", f["soul"] as? String)
                fileBlock("IDENTITY.md", f["identity"] as? String)
                fileBlock("MEMORY.md · private", f["private_memory"] as? String)
                fileBlock("DREAMS.md", f["dreams"] as? String)
                if let paths = f["paths"] as? [String: Any], let a = paths["agent"] as? String {
                    Text(a).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
                }
            } else {
                Text("Couldn't read this agent's files.").font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }

    private func fileBlock(_ title: String, _ text: String?) -> some View {
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return DisclosureGroup {
            Text(body.isEmpty ? "Empty." : String(body.prefix(6000)) + (body.count > 6000 ? "\n…" : ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(body.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            Text(title).font(.system(size: 12))
        }
    }

    private func loadFiles() async {
        guard let ws = store.workspaceId, let id = selectedId else { return }
        filesLoading = true
        files = await ColonyService.fetchRoleFiles(workspaceId: ws, roleId: id)
        filesLoading = false
    }

    private var profileTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Name") { TextField("", text: strBinding("name")).textFieldStyle(.roundedBorder) }
            field("Model") {
                HStack {
                    Picker("", selection: strBinding("model")) {
                        let current = draft["model"] as? String ?? ""
                        if !store.models.contains(where: { $0.id == current }) { Text(current).tag(current) }
                        ForEach(store.models) { m in Text(m.label).tag(m.id) }
                    }
                    .labelsHidden().frame(maxWidth: 300)
                    Button(testing ? "Testing…" : "Test this model") { testModel() }.disabled(testing)
                    if let t = testResult {
                        Text(t.text).font(.system(size: 11)).foregroundColor(t.ok ? .green : .red).lineLimit(2)
                    }
                }
            }
            field("When should this agent answer?") {
                TextEditor(text: strBinding("when")).font(.system(size: 13)).frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }
            Text("The decider uses this to choose. Be specific so agents don't overlap.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private var personalityTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("How should this agent answer?") {
                TextEditor(text: strBinding("instructions")).font(.system(size: 13)).frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            }
            Text("Becomes this agent's SOUL.md. Changing it starts a fresh session for the agent.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    // MARK: Skills (added and removed at once, not part of Save)

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let list = skills {
                if list.isEmpty {
                    Text("This agent has no skills yet. A skill is a folder with a SKILL.md file.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                ForEach(list) { skill in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.system(size: 12, weight: .medium))
                            if !skill.description.isEmpty {
                                Text(skill.description).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button { removeSkill(skill) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove from this agent")
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text("Loading…").font(.system(size: 12)).foregroundColor(.secondary)
            }
            Button { addSkillFolder() } label: { Label("Add from folder…", systemImage: "folder.badge.plus") }
            HStack {
                TextField("https://github.com/owner/repo", text: $githubURL).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Button(downloading ? "Downloading…" : "Add from GitHub") { addSkillsFromGithub() }
                    .disabled(downloading || githubURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let m = message {
                Text(m).font(.system(size: 12)).foregroundColor(messageIsError ? .red : .secondary)
            }
            Text("Only this agent can use its skills. In the group chat, each agent that answers uses its own.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    /// Settings → Colony → Gateway: can this app talk to the OpenClaw Gateway directly?
    private func checkGateway() {
        gatewayStatus = "Connecting…"
        Task { gatewayStatus = await GatewayClient.shared.describe() }
    }

    private func loadSkills() async {
        guard let ws = store.workspaceId, let id = selectedId else { return }
        skills = await ColonyService.fetchSkills(workspaceId: ws, roleId: id)
    }

    private func addSkillFolder() {
        guard let ws = store.workspaceId, let id = selectedId else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add skill"
        panel.message = "Choose a skill folder (it has a SKILL.md), or a folder of skills."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        changeSkills { try await ColonyService.addSkills(workspaceId: ws, roleId: id, folder: url.path) }
    }

    private func addSkillsFromGithub() {
        guard let ws = store.workspaceId, let id = selectedId else { return }
        let url = githubURL.trimmingCharacters(in: .whitespaces)
        downloading = true
        message = nil
        Task {
            defer { downloading = false }
            do {
                skills = try await ColonyService.addSkillsFromGithub(workspaceId: ws, roleId: id, url: url)
                githubURL = ""
                messageIsError = false
            } catch {
                messageIsError = true
                message = error.localizedDescription
            }
        }
    }

    private func removeSkill(_ skill: ColonyService.Skill) {
        guard let ws = store.workspaceId, let id = selectedId else { return }
        changeSkills { try await ColonyService.removeSkill(workspaceId: ws, roleId: id, id: skill.id) }
    }

    private func changeSkills(_ run: @escaping () async throws -> [ColonyService.Skill]) {
        Task {
            do { skills = try await run(); messageIsError = false; message = nil }
            catch { messageIsError = true; message = error.localizedDescription }
        }
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolToggle("Read files", key: "read", on: "allow")
            toolToggle("Write files (asks first)", key: "write", on: "ask")
            toolToggle("Run commands (asks first)", key: "bash", on: "ask")
            Toggle("Search the web", isOn: Binding(
                get: { draft["web_search"] as? Bool ?? false },
                set: { draft["web_search"] = $0 }))
            Toggle("Accept tasks from teammates", isOn: Binding(
                get: { draft["accepts_handoff"] as? Bool ?? false },
                set: { draft["accepts_handoff"] = $0 }))
            Text("When on, a teammate can hand this agent a task in the group chat (a reply ending in @Name). Off: only you can ask it.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Toggle("Can ask teammates for help", isOn: Binding(
                get: { draft["delegates"] as? Bool ?? false },
                set: { draft["delegates"] = $0 }))
            Text("When on, this agent can send part of its work to teammates that accept tasks (above) and then answers you with the result. Save to apply.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text("Tools need a model that can use them, and a project folder set on the workspace.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Divider()
            appsSection
        }
        .task { composio = await ColonyService.composioConnected() }
    }

    // MARK: Apps (Gmail, Slack, … through Composio)

    private static let popularApps = [
        "Gmail", "Google Calendar", "Google Drive", "Google Docs", "Google Sheets", "Slack", "Notion",
        "GitHub", "Outlook", "Microsoft Teams", "OneDrive", "Discord", "Trello", "Asana", "Jira",
        "Linear", "HubSpot", "Salesforce", "Dropbox", "Airtable", "Zoom", "Stripe", "Shopify", "X (Twitter)",
    ]

    private var appsSection: some View {
        let tools = draft["tools"] as? [String: Any] ?? [:]
        let apps = tools["mcp_apps"] as? [String] ?? []
        let mode = tools["mcp"] as? String ?? "off"
        let custom = apps.filter { a in !Self.popularApps.contains { $0.lowercased() == a.lowercased() } }
        let chips = Self.popularApps + custom
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(composio == nil ? "Checking…" : (composio! ? "Composio connected" : "Composio not connected"))
                    .font(.system(size: 11)).foregroundColor(composio == true ? .green : .secondary)
            }
            if composio == false {
                Text("Add your Composio key in Colony first (POST /api/mcp/composio). Then agents can use Gmail, Slack, Notion and 1,000+ other apps.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Toggle("Let this agent use my apps", isOn: Binding(
                get: { mode != "off" },
                set: { v in var t = tools; t["mcp"] = v ? "ask" : "off"; draft["tools"] = t }))
            Text("Read emails, check the calendar, post to Slack and more, on your behalf.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            if mode != "off" {
                Picker("", selection: Binding(
                    get: { mode },
                    set: { v in var t = tools; t["mcp"] = v; draft["tools"] = t })) {
                    Text("Ask me before acting").tag("ask")
                    Text("Act on its own").tag("allow")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)

                Text("Which apps?").font(.system(size: 12, weight: .medium)).padding(.top, 4)
                Button { showAppPicker.toggle() } label: {
                    HStack {
                        Text(apps.isEmpty ? "Any app (tap to choose)" : "\(apps.count) selected: tap to change")
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).frame(maxWidth: 320)
                .popover(isPresented: $showAppPicker, arrowEdge: .bottom) { appPicker(apps) }
                if !apps.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(apps, id: \.self) { name in
                            Button { setApps(apps.filter { $0 != name }) } label: {
                                HStack(spacing: 4) {
                                    Text(name).font(.system(size: 12)).lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("The first time an agent uses an app, it gives you a link to sign in.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    private func appPicker(_ apps: [String]) -> some View {
        let query = newApp.trimmingCharacters(in: .whitespaces)
        let all = Self.popularApps + apps.filter { a in !Self.popularApps.contains { $0.lowercased() == a.lowercased() } }
        let shown = query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Search or type another app", text: $newApp)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addApp(apps) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { name in
                        let on = apps.contains { $0.lowercased() == name.lowercased() }
                        Button {
                            setApps(on ? apps.filter { $0.lowercased() != name.lowercased() } : apps + [name])
                        } label: {
                            HStack {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundColor(on ? .accentColor : .secondary)
                                Text(name).font(.system(size: 12))
                                Spacer()
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !query.isEmpty, !all.contains(where: { $0.lowercased() == query.lowercased() }) {
                        Button("Add \"\(query)\"") { addApp(apps) }.padding(.top, 6)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(12).frame(width: 260)
    }

    private func setApps(_ apps: [String]) {
        var t = draft["tools"] as? [String: Any] ?? [:]
        t["mcp_apps"] = apps
        draft["tools"] = t
    }

    private func addApp(_ apps: [String]) {
        let name = newApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !apps.contains(name) else { return }
        setApps(apps + [name])
        newApp = ""
    }

    private func toolToggle(_ title: String, key: String, on: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { (draft["tools"] as? [String: Any])?[key] as? String ?? "off" != "off" },
            set: { v in
                var t = draft["tools"] as? [String: Any] ?? [:]
                t[key] = v ? on : "off"
                draft["tools"] = t
            }))
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundColor(.secondary)
            content()
        }
    }

    private func strBinding(_ key: String) -> Binding<String> {
        Binding(get: { draft[key] as? String ?? "" }, set: { draft[key] = $0 })
    }

    // MARK: Actions

    private func loadRoles() async {
        guard let ws = store.workspaceId else { return }
        roles = await ColonyService.fetchRoles(workspaceId: ws)
        let keep = roles.contains { $0["id"] as? String == selectedId } ? selectedId : (roles.first?["id"] as? String)
        if let keep { select(keep) } else { selectedId = nil }
    }

    private func select(_ id: String) {
        selectedId = id
        draft = roles.first { $0["id"] as? String == id } ?? [:]
        testResult = nil; message = nil
    }

    private func addAgent() {
        let id = "agent-" + String(UUID().uuidString.prefix(6)).lowercased()
        let model = store.models.first?.id ?? "ollama/qwen3:8b"
        roles.append(["id": id, "name": "New agent", "model": model,
                      "when": "Describe when this agent should answer.", "instructions": ""])
        select(id)
        tab = .profile
    }

    private func save() {
        guard let ws = store.workspaceId, let id = selectedId else { return }
        var all = roles
        guard let i = all.firstIndex(where: { $0["id"] as? String == id }) else { return }
        all[i] = draft
        persist(all, ws: ws, keep: id, ok: "Saved")
    }

    private func deleteSelected() {
        guard let ws = store.workspaceId, let id = selectedId else { return }
        persist(roles.filter { $0["id"] as? String != id }, ws: ws, keep: nil, ok: "Agent deleted")
    }

    private func persist(_ all: [[String: Any]], ws: String, keep: String?, ok: String) {
        Task {
            do {
                try await ColonyService.saveRoles(workspaceId: ws, roles: all)
                roles = all
                messageIsError = false
                await store.reload()
                await loadRoles()
                if let keep { select(keep) }
                message = ok
            } catch {
                messageIsError = true
                message = error.localizedDescription
            }
        }
    }

    private func testModel() {
        guard let m = draft["model"] as? String else { return }
        testing = true; testResult = nil
        Task {
            testResult = await ColonyService.testModel(m)
            testing = false
        }
    }
}


/// "Colony agents" block of Settings → Active pills: which agents of the current workspace show on Home and in the room row.
struct ColonyAgentPills: View {
    @ObservedObject private var store = ColonyStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Colony agents · \(store.workspaceName)")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            if store.agents.isEmpty {
                Text(store.offline ? "Colony isn't running." : "Loading team…")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(store.agents) { a in
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: a.color)).frame(width: 10, height: 10)
                    Text(a.name).font(.system(size: 12))
                    Spacer()
                    Text(a.model).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    Toggle("", isOn: Binding(get: { !store.isHidden(a) }, set: { store.setHidden(a, !$0) }))
                        .labelsHidden()
                }
            }
        }
        .task { await store.reload() }
    }
}

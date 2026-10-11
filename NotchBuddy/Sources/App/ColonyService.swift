import Foundation

// MARK: - Models (what the Colony server returns)

struct ColonyAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let when: String           // the agent's "when to answer" rule: what it is the right one for
    var color: String { ColonyService.color(forAgent: id) }
}

struct ColonyModel: Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
    let tools: Bool
}

struct ColonyMessage: Identifiable, Equatable {
    let id: String
    let isUser: Bool
    let text: String
    let channel: String        // "auto" (group chat) or an agent id
    let agentId: String?
    let agentName: String?
    let confidence: Double?    // decider confidence, group chat only
    let workedSeconds: Double?
    let stepCount: Int
}

/// A reply that is still being written (streamed by the Gateway, published through /api/activity).
struct ColonyPartial: Equatable {
    let agentId: String
    let agentName: String
    let text: String
}

/// A question an agent is waiting on ("may I run this command?"); the chat shows it as a card with Allow / Deny.
struct ColonyApproval: Equatable, Identifiable {
    let id: String
    let agent: String
    let title: String
    let message: String
}

struct ColonyActivity: Equatable {
    var active = false
    var step = "idle"
    var agentName: String?
    var detail = ""

    /// One line for the chat: what the agent is doing right now ("Writer · Used skill: zebra-protocol").
    var statusLine: String? {
        guard active else { return nil }
        let what: String
        switch step {
        case "routing":                    what = "Choosing who answers…"
        case "preparing":                  what = "Getting the team ready…"
        case "approval", "waiting_approval": what = "Waiting for your OK"
        case "tool" where !detail.isEmpty: what = detail
        default:                           what = "Thinking…"
        }
        guard let name = agentName, step != "routing" else { return what }
        return name + " · " + what
    }
}

// MARK: - Service (plain HTTP to the local Colony server, no third-party code)

enum ColonyService {
    /// `colony` command listens on 8765 by default.
    static var baseURL: String {
        let raw = UserDefaults.standard.string(forKey: "colonyBaseURL") ?? "http://127.0.0.1:8765"
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// Agent colours, stable per agent id (same palette order as the Colony web UI avatars).
    static let palette = ["#F472B6", "#34D399", "#FACC15", "#60A5FA", "#E879F9", "#FB923C"]
    static func color(forAgent id: String) -> String {
        var h = 0
        for u in id.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }

    private static func get(_ path: String, timeout: TimeInterval = 5) async -> [String: Any]? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Every workspace with its agents; nil when Colony isn't running.
    static func loadWorkspaces() async -> [(id: String, name: String, agents: [ColonyAgent])]? {
        guard let json = await get("/api/workspaces"),
              let list = json["workspaces"] as? [[String: Any]], !list.isEmpty else { return nil }
        return list.compactMap { ws in
            guard let id = ws["id"] as? String else { return nil }
            let agents = (ws["agents"] as? [[String: Any]] ?? []).compactMap { a -> ColonyAgent? in
                guard let aid = a["id"] as? String, let name = a["name"] as? String else { return nil }
                return ColonyAgent(id: aid, name: name, model: a["model"] as? String ?? "", when: a["when"] as? String ?? "")
            }
            return (id, ws["name"] as? String ?? "Workspace", agents)
        }
    }

    /// Creates a workspace whose team is a copy of `copyFrom`'s; returns the new id.
    static func createWorkspace(name: String, copyFrom: String?) async throws -> String {
        guard let url = URL(string: baseURL + "/api/workspaces") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name]
        if let copyFrom { body["copy_agents_from"] = copyFrom }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = j?["id"] as? String else {
            throw NSError(domain: "Colony", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: j?["detail"] as? String ?? "The workspace couldn't be created."])
        }
        return id
    }

    /// Deletes a workspace with its conversation and memory (its project folder is left alone). Colony keeps at least one.
    static func deleteWorkspace(id: String) async throws {
        guard let url = URL(string: baseURL + "/api/workspaces/\(id)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "DELETE"
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw NSError(domain: "Colony", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: j?["detail"] as? String ?? "The workspace couldn't be deleted."])
        }
    }

    // MARK: Agents (roles) and models

    /// The workspace's agents as raw JSON, so fields this app doesn't edit survive a save untouched.
    static func fetchRoles(workspaceId: String) async -> [[String: Any]] {
        let j = await get("/api/roles?workspace_id=\(workspaceId)")
        return j?["roles"] as? [[String: Any]] ?? []
    }

    /// Replaces the workspace's agents. Throws the server's own explanation (e.g. "model can't use tools").
    static func saveRoles(workspaceId: String, roles: [[String: Any]]) async throws {
        guard let url = URL(string: baseURL + "/api/roles?workspace_id=\(workspaceId)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["roles": roles])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw NSError(domain: "Colony", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: j?["detail"] as? String ?? "The agents couldn't be saved."])
        }
    }

    /// What an agent is as files (persona, identity, its own memory) plus the team's shared memory.
    static func fetchRoleFiles(workspaceId: String, roleId: String) async -> [String: Any]? {
        await get("/api/roles/\(roleId)/files?workspace_id=\(workspaceId)", timeout: 10)
    }

    // MARK: Skills (each belongs to one agent)

    struct Skill: Identifiable { let id: String; let name: String; let description: String }

    private static func skills(from j: [String: Any]?) -> [Skill] {
        (j?["skills"] as? [[String: Any]] ?? []).compactMap { s in
            guard let folder = s["folder"] as? String else { return nil }
            return Skill(id: folder, name: s["name"] as? String ?? folder, description: s["description"] as? String ?? "")
        }
    }

    static func fetchSkills(workspaceId: String, roleId: String) async -> [Skill] {
        skills(from: await get("/api/roles/\(roleId)/skills?workspace_id=\(workspaceId)"))
    }

    /// Copies the skill(s) in `folder` to the agent. Throws the server's own explanation (e.g. "No skill found there").
    static func addSkills(workspaceId: String, roleId: String, folder: String) async throws -> [Skill] {
        try await skillRequest("POST", "/api/roles/\(roleId)/skills?workspace_id=\(workspaceId)", body: ["path": folder])
    }

    /// Downloads a public GitHub repository once and gives the agent every skill in it.
    static func addSkillsFromGithub(workspaceId: String, roleId: String, url: String) async throws -> [Skill] {
        try await skillRequest("POST", "/api/roles/\(roleId)/skills/github?workspace_id=\(workspaceId)", body: ["url": url], timeout: 180)
    }

    static func removeSkill(workspaceId: String, roleId: String, id: String) async throws -> [Skill] {
        try await skillRequest("DELETE", "/api/roles/\(roleId)/skills/\(id)?workspace_id=\(workspaceId)", body: nil)
    }

    private static func skillRequest(_ method: String, _ path: String, body: [String: Any]?,
                                     timeout: TimeInterval = 30) async throws -> [Skill] {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Colony", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: j?["detail"] as? String ?? "The skill couldn't be changed."])
        }
        return skills(from: j)
    }

    static func fetchModels() async -> [ColonyModel] {
        guard let j = await get("/api/models"), let list = j["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let caps = m["capabilities"] as? [String: Any] ?? [:]
            return ColonyModel(id: id, label: m["label"] as? String ?? id, note: m["note"] as? String ?? "",
                               tools: caps["tools"] as? Bool ?? true)
        }
    }

    /// One tiny message to the model. Returns a human line either way.
    static func testModel(_ id: String) async -> (ok: Bool, text: String) {
        guard let url = URL(string: baseURL + "/api/models/test") else { return (false, "Bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": id])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "Colony didn't answer.")
        }
        if j["ok"] as? Bool == true {
            return (true, "Works · \(j["seconds"] as? Double ?? 0)s")
        }
        return (false, j["message"] as? String ?? "The model didn't answer.")
    }

    static func loadMessages(workspaceId: String) async -> [ColonyMessage] {
        guard let json = await get("/api/workspaces/\(workspaceId)/messages", timeout: 10),
              let raw = json["messages"] as? [[String: Any]] else { return [] }
        var lastChannel = "auto"
        return raw.compactMap { m -> ColonyMessage? in
            guard let id = m["id"] as? String, let text = m["content"] as? String else { return nil }
            let role = m["role"] as? String ?? "assistant"
            if role == "user" {
                lastChannel = m["channel"] as? String ?? "auto"
                return ColonyMessage(id: id, isUser: true, text: text, channel: lastChannel, agentId: nil,
                                     agentName: nil, confidence: nil, workedSeconds: nil, stepCount: 0)
            }
            let meta = m["metadata"] as? [String: Any] ?? [:]
            return ColonyMessage(id: id, isUser: false, text: text,
                                 channel: meta["channel"] as? String ?? lastChannel,
                                 agentId: meta["role_id"] as? String,
                                 agentName: meta["role_name"] as? String,
                                 confidence: meta["confidence"] as? Double,
                                 workedSeconds: meta["worked_s"] as? Double,
                                 stepCount: (meta["steps"] as? [Any])?.count ?? 0)
        }
    }

    /// One turn. `channel` "auto" = group chat (Colony's decider picks), otherwise the agent id.
    /// A turn to run with the Gateway itself (see colony/core/native_turn.py).
    struct NativeTurn {
        let turnId: String
        let agentId: String
        let session: String
        let model: String
        let roleId: String
        let roleName: String
        let message: String
        let attachments: [[String: Any]]      // images and PDFs, as `chat.send` takes them
        let cwd: String?                      // the folder the Gateway fences this turn to
        let permissionMode: String?           // read-only | guarded
    }

    private static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Colony", code: 400, userInfo: [NSLocalizedDescriptionKey: json["detail"] as? String ?? "The request failed."])
        }
        return json
    }

    /// Sets the agent up and returns what to send the Gateway; nil when this message should take the normal path.
    /// `room` is "auto" (the group chat: the decider picks who answers) or an agent's id.
    static func prepareTurn(workspaceId: String, text: String, room: String, attachments: [String] = []) async -> NativeTurn? {
        var body: [String: Any] = ["workspace_id": workspaceId, "message": text, "channel": room]
        if room != "auto" { body["role_id"] = room }
        if !attachments.isEmpty { body["attachments"] = attachments }
        guard let j = try? await post("/api/turns/prepare", body, timeout: 240),
              j["native"] as? Bool == true, let turn = j["turn_id"] as? String, let agent = j["agent_id"] as? String,
              let session = j["session"] as? String, let message = j["message"] as? String else { return nil }
        return NativeTurn(turnId: turn, agentId: agent, session: session, model: j["model"] as? String ?? "",
                          roleId: j["role_id"] as? String ?? agent, roleName: j["role_name"] as? String ?? agent, message: message,
                          attachments: j["attachments"] as? [[String: Any]] ?? [],
                          cwd: j["cwd"] as? String, permissionMode: j["permission_mode"] as? String)
    }

    /// The Gateway turn is over: Colony saves the reply into the team's conversation.
    static func finishTurn(id: String, reply: String?, failed: Bool) async {
        var body: [String: Any] = ["turn_id": id, "failed": failed]
        if let reply { body["reply"] = reply }
        _ = try? await post("/api/turns/finish", body, timeout: 30)
    }

    static func send(workspaceId: String, text: String, channel: String, attachments: [String] = []) async throws -> ColonyMessage {
        guard let url = URL(string: baseURL + "/api/messages") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["workspace_id": workspaceId, "message": text, "channel": channel]
        if channel != "auto" { body["role_id"] = channel }
        if !attachments.isEmpty { body["attachments"] = attachments }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard http.statusCode == 200 else {
            throw NSError(domain: "Colony", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: json["detail"] as? String ?? "HTTP \(http.statusCode)"])
        }
        return ColonyMessage(id: json["message_id"] as? String ?? UUID().uuidString, isUser: false,
                             text: json["reply"] as? String ?? "",
                             channel: json["channel"] as? String ?? channel,
                             agentId: json["role_id"] as? String, agentName: json["role_name"] as? String,
                             confidence: json["confidence"] as? Double,
                             workedSeconds: json["worked_s"] as? Double,
                             stepCount: (json["steps"] as? [Any])?.count ?? 0)
    }

    /// Uploads a file into the workspace and returns its attachment id. Colony reads files up to its own limit.
    static func upload(workspaceId: String, fileURL: URL) async throws -> String {
        guard let url = URL(string: baseURL + "/api/workspaces/\(workspaceId)/attachments") else { throw URLError(.badURL) }
        let data = try Data(contentsOf: fileURL)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": fileURL.lastPathComponent, "data": data.base64EncodedString()])
        let (body, resp) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = json["id"] as? String else {
            throw NSError(domain: "Colony", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: json["detail"] as? String ?? "The file couldn't be attached."])
        }
        return id
    }

    /// Is each part of the stack up? Colony itself, the OpenClaw Gateway, and Laya (the # mix decider).
    static func health() async -> (colony: Bool, gateway: Bool, laya: Bool) {
        async let c = get("/api/health", timeout: 2)
        async let g = get("/api/openclaw/status", timeout: 2)
        let laya: Bool = await {
            guard let url = URL(string: "http://127.0.0.1:8790/health") else { return false }
            let req = URLRequest(url: url, timeoutInterval: 2)
            guard let (_, r) = try? await URLSession.shared.data(for: req) else { return false }
            return (r as? HTTPURLResponse)?.statusCode == 200
        }()
        let gw = await g
        return (await c != nil, gw?["available"] as? Bool ?? false, laya)
    }

    /// Live status plus the reply as far as the model has written it (nil when nothing is being written).
    static func activity(workspaceId: String) async -> (ColonyActivity, ColonyPartial?) {
        guard let j = await get("/api/activity?workspace_id=\(workspaceId)", timeout: 3) else { return (ColonyActivity(), nil) }
        let a = ColonyActivity(active: j["active"] as? Bool ?? false, step: j["step"] as? String ?? "idle",
                               agentName: j["agent_name"] as? String, detail: j["detail"] as? String ?? "")
        var partial: ColonyPartial?
        if let p = j["partial"] as? [String: Any], let text = p["text"] as? String, !text.isEmpty {
            partial = ColonyPartial(agentId: p["role_id"] as? String ?? "", agentName: p["agent_name"] as? String ?? "", text: text)
        }
        return (a, partial)
    }

    static func approvals() async -> [ColonyApproval] {
        guard let j = await get("/api/approvals", timeout: 3), let list = j["approvals"] as? [[String: Any]] else { return [] }
        return list.compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            return ColonyApproval(id: id, agent: a["agent"] as? String ?? "", title: a["title"] as? String ?? "",
                                  message: a["message"] as? String ?? "")
        }
    }

    static func answerApproval(id: String, approve: Bool) async {
        guard let url = URL(string: baseURL + "/api/approvals/\(id)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["approve": approve])
        _ = try? await URLSession.shared.data(for: req)     // 404 = it timed out meanwhile; nothing to do
    }

    /// Mochi's pose for what the server is doing.
    static func botState(for a: ColonyActivity) -> BotState? {
        guard a.active else { return nil }
        switch a.step {
        case "approval", "waiting_approval": return .approval
        case "searching", "web_search":      return .searching
        case "thinking", "preparing":        return .thinking
        default:                             return .working
        }
    }
}

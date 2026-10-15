import Foundation
import CryptoKit
import Security

// Direct connection from Coucou to the OpenClaw Gateway (WebSocket, protocol v4, the same one OpenClaw's own apps use).
// Foundation + CryptoKit only. The Gateway runs the agents, tools, skills and approvals; this file only talks to it.
//
// Handshake: the Gateway sends `connect.challenge`; we answer with `connect` as the macOS app (`openclaw-macos`, mode `ui`)
// and sign the challenge with a device key kept in the Keychain. On this Mac the Gateway pairs a new device by itself.

/// An action an agent wants to do and waits for the user's answer on (the Gateway's own exec approval).
struct GatewayApproval: Equatable, Identifiable {
    let id: String
    let command: String
    let agentId: String
    let sessionKey: String
}

struct GatewayAgentInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let model: String
}

/// What happens during one turn, in the order it happens.
enum GatewayChatEvent {
    case status(String)                                           // "preparing_workspace", "starting_model", ...
    case delta(String)                                            // the next piece of the reply
    case tool(title: String, detail: String, done: Bool, ok: Bool)
    case approval(GatewayApproval)
    case final(String)                                            // the whole reply; the stream ends after it
}

/// A slash command the Gateway understands (`/status`, `/skill <name>`, `/think` ...).
struct GatewayCommand: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let usage: String       // "<name> [input]": its arguments, required ones in <>, optional ones in []
}

enum GatewayError: LocalizedError {
    case closed
    case timeout
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .closed:           return "The connection to the OpenClaw Gateway was lost."
        case .timeout:          return "The OpenClaw Gateway did not answer in time."
        case .rejected(let m):  return m
        }
    }
}

actor GatewayClient {
    static let shared = GatewayClient()

    /// `ws://127.0.0.1:18789` unless the user changed it.
    static var url: String { UserDefaults.standard.string(forKey: "gatewayURL") ?? "ws://127.0.0.1:18789" }

    private static let clientId = "openclaw-macos"
    private static let clientMode = "ui"
    // admin: the Gateway only lets a session be fenced to a folder outside its own agent workspaces (the project folder)
    // with it. On this Mac the Gateway grants it to the app by itself (loopback).
    private static let scopes = ["operator.read", "operator.write", "operator.approvals", "operator.admin"]

    private var socket: URLSessionWebSocketTask?
    private var connected = false
    private var connecting: Task<Void, Error>?
    private var nextId = 0
    private var waiting: [String: AsyncThrowingStream<[String: Any], Error>.Continuation] = [:]
    private var listeners: [UUID: (String, [String: Any]) -> Void] = [:]

    // MARK: Connection

    func ensureConnected() async throws {
        if connected { return }
        if let attempt = connecting { return try await attempt.value }
        let attempt = Task { try await self.open() }
        connecting = attempt
        defer { connecting = nil }
        try await attempt.value
    }

    private func open() async throws {
        guard let url = URL(string: Self.url) else { throw GatewayError.rejected("The Gateway address is not valid.") }
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        var challenge = try await Self.readFrame(ws)
        var guardCount = 0
        while challenge["event"] as? String != "connect.challenge" && guardCount < 5 {      // skip anything sent before it
            challenge = try await Self.readFrame(ws); guardCount += 1
        }
        let payload = challenge["payload"] as? [String: Any] ?? [:]
        let nonce = payload["nonce"] as? String ?? ""
        let signedAt = (payload["ts"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)

        let key = try Self.deviceKey()
        let rawPublic = key.publicKey.rawRepresentation
        let deviceId = SHA256.hash(data: rawPublic).map { String(format: "%02x", $0) }.joined()
        let signed = ["v3", deviceId, Self.clientId, Self.clientMode, "operator", Self.scopes.joined(separator: ","),
                      String(signedAt), "", nonce, "macos", ""].joined(separator: "|")
        let signature = try key.signature(for: Data(signed.utf8))

        let connectParams: [String: Any] = [
            "minProtocol": 4, "maxProtocol": 4,
            "client": ["id": Self.clientId, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                       "platform": "macos", "mode": Self.clientMode],
            "role": "operator", "scopes": Self.scopes,
            "caps": ["tool-events", "approvals", "exec-approvals", "plugin-approvals", "session-scoped-events"],
            "commands": [String](), "permissions": [String: Any](),
            "locale": Locale.current.identifier, "userAgent": "coucou/colony",
            "device": ["id": deviceId, "publicKey": Self.base64URL(rawPublic), "signature": Self.base64URL(signature),
                       "signedAt": signedAt, "nonce": nonce],
        ]
        nextId += 1
        let id = "c\(nextId)"
        try await ws.send(.string(Self.json(["type": "req", "id": id, "method": "connect", "params": connectParams])))
        while true {
            let frame = try await Self.readFrame(ws)
            guard frame["type"] as? String == "res", frame["id"] as? String == id else { continue }
            if frame["ok"] as? Bool == true { break }
            let err = frame["error"] as? [String: Any]
            throw GatewayError.rejected(err?["message"] as? String ?? "The Gateway refused the connection.")
        }
        socket = ws
        connected = true
        Task { [weak self] in
            while true {
                do { await self?.handle(try await Self.readFrame(ws)) }
                catch { await self?.dropped(ws); return }
            }
        }
    }

    private func dropped(_ ws: URLSessionWebSocketTask) {
        guard socket === ws else { return }
        socket = nil
        connected = false
        let stuck = waiting
        waiting = [:]
        stuck.values.forEach { $0.finish(throwing: GatewayError.closed) }
        listeners.values.forEach { $0("gateway.closed", [:]) }
    }

    private func handle(_ frame: [String: Any]) {
        switch frame["type"] as? String {
        case "res":
            guard let id = frame["id"] as? String, let cont = waiting.removeValue(forKey: id) else { return }
            if frame["ok"] as? Bool == true {
                cont.yield(frame["payload"] as? [String: Any] ?? [:])
                cont.finish()
            } else {
                let err = frame["error"] as? [String: Any]
                cont.finish(throwing: GatewayError.rejected(err?["message"] as? String ?? "The Gateway refused the request."))
            }
        case "event":
            let name = frame["event"] as? String ?? ""
            let payload = frame["payload"] as? [String: Any] ?? [:]
            listeners.values.forEach { $0(name, payload) }
        default:
            break
        }
    }

    /// One request and its answer's payload. Throws what the Gateway says when it refuses.
    func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        try await ensureConnected()
        guard let ws = socket else { throw GatewayError.closed }
        nextId += 1
        let id = "r\(nextId)"
        var answer: AsyncThrowingStream<[String: Any], Error>.Continuation!
        let stream = AsyncThrowingStream<[String: Any], Error> { answer = $0 }
        waiting[id] = answer
        let me = self
        Task {
            do { try await ws.send(.string(Self.json(["type": "req", "id": id, "method": method, "params": params]))) }
            catch { await me.fail(id, GatewayError.closed) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await me.fail(id, GatewayError.timeout)
        }
        for try await payload in stream { return payload }
        throw GatewayError.closed
    }

    private func fail(_ id: String, _ error: Error) {
        waiting.removeValue(forKey: id)?.finish(throwing: error)
    }

    // MARK: What the app needs

    /// The agents the Gateway has (the ones Colony wrote into OpenClaw's config, plus `main`).
    func agents() async throws -> [GatewayAgentInfo] {
        let reply = try await request("agents.list")
        return (reply["agents"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            let model = (a["model"] as? [String: Any])?["primary"] as? String ?? ""
            return GatewayAgentInfo(id: id, name: a["name"] as? String ?? id, model: model)
        }
    }

    /// The slash commands this Gateway has, for the chat's "/" menu.
    func commands() async -> [GatewayCommand] {
        guard let reply = try? await request("commands.list") else { return [] }
        return (reply["commands"] as? [[String: Any]] ?? []).compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            let args = (c["args"] as? [[String: Any]] ?? []).compactMap { a -> String? in
                guard let n = a["name"] as? String else { return nil }
                return a["required"] as? Bool == true ? "<\(n)>" : "[\(n)]"
            }
            return GatewayCommand(name: name, description: c["description"] as? String ?? "", usage: args.joined(separator: " "))
        }
    }

    /// One line for Settings: whether the Gateway is reachable and what it has.
    func describe() async -> String {
        do {
            let list = try await agents()
            return "Connected · \(list.count) agents"
        } catch {
            return error.localizedDescription
        }
    }

    /// Answer a question an agent is waiting on.
    func resolveApproval(id: String, allow: Bool) async {
        _ = try? await request("exec.approval.resolve", ["id": id, "decision": allow ? "allow-once" : "deny"])
    }

    /// One turn with one agent, as a stream of what happens. The session is the conversation: the same `session` name
    /// continues the same conversation. `model` / `permissionMode` (read-only | guarded | workspace | full) are set on it first.
    /// `attachments` are ready-made `chat.send` attachments (images and PDFs: type, mimeType, fileName, base64 content).
    /// `cwd` is the folder the session is fenced to; with `permissionMode` it is set when the session is created.
    func chat(agentId: String, session: String, text: String, model: String? = nil, permissionMode: String? = nil,
              cwd: String? = nil, attachments: [[String: Any]] = []) -> AsyncThrowingStream<GatewayChatEvent, Error> {
        let key = "agent:\(agentId):\(session)"
        var out: AsyncThrowingStream<GatewayChatEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<GatewayChatEvent, Error> { out = $0 }
        let cont = out!
        let listener = UUID()
        var reply = ""
        // A teammate spawned through OpenClaw (sessions_spawn) answers in a LATER run of this same session: the first
        // `final` is only "waiting". Keep the stream open for that second final (measured on a Gateway 2026-10-14).
        var spawned = false, waitedOnce = false
        var waitTimer: Task<Void, Never>?
        listeners[listener] = { event, p in
            if event == "gateway.closed" { cont.finish(throwing: GatewayError.closed); return }
            guard (p["sessionKey"] as? String ?? (p["request"] as? [String: Any])?["sessionKey"] as? String) == key else { return }
            switch event {
            case "chat":
                switch p["state"] as? String {
                case "status":
                    cont.yield(.status(p["phase"] as? String ?? ""))
                case "final":
                    let parts = (p["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    let full = parts.compactMap { $0["text"] as? String }.joined()
                    let answer = full.isEmpty ? reply : full
                    if spawned && !waitedOnce {
                        waitedOnce = true
                        cont.yield(.status("waiting_helpers"))
                        waitTimer = Task {      // ponytail: if no second run ever comes, end with what we have
                            try? await Task.sleep(nanoseconds: 180_000_000_000)
                            if !Task.isCancelled { cont.yield(.final(answer)); cont.finish() }
                        }
                        return
                    }
                    waitTimer?.cancel()
                    cont.yield(.final(answer))
                    cont.finish()
                case "error", "aborted":
                    cont.finish(throwing: GatewayError.rejected(p["errorMessage"] as? String ?? "The reply stopped."))
                default:
                    break
                }
            case "agent":
                let data = p["data"] as? [String: Any] ?? [:]
                switch p["stream"] as? String {
                case "assistant":
                    if let d = data["delta"] as? String { reply += d; cont.yield(.delta(d)) }
                case "tool":
                    let args = data["args"] as? [String: Any] ?? [:]
                    let name = data["name"] as? String ?? "tool"
                    let done = data["phase"] as? String == "result"
                    let asking = name.hasSuffix("sessions_spawn")      // the Gateway may qualify the name ("openclaw:core:sessions_spawn")
                    if asking { spawned = true }
                    cont.yield(.tool(title: asking ? "Asking a teammate" : name.hasSuffix("sessions_yield") ? "Waiting for the teammate" : args["title"] as? String ?? name,
                                     detail: asking ? String((args["task"] as? String ?? "").prefix(80))
                                                    : args["command"] as? String ?? args["path"] as? String ?? "",
                                     done: done, ok: data["isError"] as? Bool != true))
                default:
                    break
                }
            case "exec.approval.requested":
                let r = p["request"] as? [String: Any] ?? [:]
                cont.yield(.approval(GatewayApproval(id: p["id"] as? String ?? "", command: r["command"] as? String ?? "",
                                                     agentId: r["agentId"] as? String ?? agentId, sessionKey: key)))
            default:
                break
            }
        }
        let me = self
        out.onTermination = { _ in Task { await me.removeListener(listener) } }
        Task {
            do {
                var create: [String: Any] = ["key": key, "agentId": agentId]
                if let cwd { create["cwd"] = cwd }
                if let permissionMode { create["permissionMode"] = permissionMode }
                _ = try await self.request("sessions.create", create)      // makes the session, or adopts the one that exists
                if let model {      // the Gateway answers "retry" when the session was only just busy: try again a few times
                    for attempt in 1...4 {
                        do { _ = try await self.request("sessions.patch", ["key": key, "model": model]); break }
                        catch GatewayError.rejected(let why) where attempt < 4 && why.localizedCaseInsensitiveContains("retry") {
                            try await Task.sleep(nanoseconds: 1_500_000_000)
                        }
                    }
                }
                _ = try await self.request("sessions.messages.subscribe", ["key": key])
                var send: [String: Any] = ["sessionKey": key, "agentId": agentId, "message": text,
                                           "idempotencyKey": UUID().uuidString]
                if !attachments.isEmpty { send["attachments"] = attachments }
                _ = try await self.request("chat.send", send, timeout: 120)
            } catch {
                cont.finish(throwing: error)
            }
        }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

    private var reminderListener: UUID?
    private var subscribedSocket: URLSessionWebSocketTask?

    /// Reminders: calls `handler(title, text, sessionKey)` when an automation (the agents' `cron` tool) has run.
    /// Safe to call again and again: it reconnects after a drop and re-subscribes, the handler is set once.
    /// `cron` events are scoped to sessions this connection subscribed to, so it subscribes to the roster as well
    /// (chat turns subscribe to their own session). ponytail: not verified live that the roster subscription is enough.
    func watchReminders(_ handler: @escaping (String, String, String) -> Void) async {
        guard (try? await ensureConnected()) != nil, let ws = socket else { return }
        if reminderListener == nil {
            let id = UUID()
            reminderListener = id
            listeners[id] = { event, p in
                guard event == "cron", p["action"] as? String == "finished" else { return }
                let job = p["job"] as? [String: Any] ?? [:]
                let title = job["name"] as? String ?? "Reminder"
                // the reminder's own text; the run's summary can carry the model's thinking-aloud
                let own = (job["payload"] as? [String: Any])?["message"] as? String
                let text = own ?? (p["summary"] as? String) ?? ""
                handler(title, text, p["sessionKey"] as? String ?? "")
            }
        }
        if subscribedSocket !== ws {
            subscribedSocket = ws
            _ = try? await request("sessions.subscribe")
        }
    }

    // MARK: Plumbing

    private static func readFrame(_ ws: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await ws.receive()
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// This Mac's device key: made once, kept in the Keychain. The Gateway knows the app by its public half.
    private static func deviceKey() throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "coucou.openclaw-gateway", kSecAttrAccount as String: "device-key"]
        var found: CFTypeRef?
        if SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found) == errSecSuccess,
           let data = found as? Data, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query.merging([kSecValueData as String: key.rawRepresentation]) { $1 } as CFDictionary, nil)
        return key
    }
}

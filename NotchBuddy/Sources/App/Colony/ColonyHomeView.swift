import SwiftUI

/// Home (overview) when Colony is on: who is on the team and what each agent is doing.
/// Tapping an agent (or the group) opens its room in the chat.
struct ColonyHomeView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = ColonyStore.shared
    @State private var swapping = false
    @State private var integrationId: String?     // an integration pill (GitHub, Stripe…) the user opened
    @State private var showingDetail = false
    @State private var showTools = false
    @State private var swipe: CGFloat = 0           // horizontal trackpad travel of the current two-finger swipe
    @State private var swipeMonitor: Any?

    private var focus: ColonyAgent? { store.currentAgent ?? store.agents.first }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)
                if let t = state.tasks.first(where: { $0.id == integrationId && $0.isIntegration }) {
                    IntegrationCardView(task: t, showingDetail: $showingDetail)   // same card Coucou's Home shows
                } else {
                    leftCard.padding(.leading, 108).padding(.trailing, 36).padding(.vertical, 12)
                }
            }
            ZStack {
                CardBackground(wash: nil)
                rightCard.padding(8)
            }
            .frame(width: 320)
        }
        .padding(.bottom, 10)
        .task { await store.reload() }
        .task { await store.pollActivity(state: state) }
        .onAppear { startSwipeMonitor() }
        .onDisappear { if let m = swipeMonitor { NSEvent.removeMonitor(m); swipeMonitor = nil } }
    }

    private func setTools(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { showTools = on }
        if on { if let first = tools.first { state.setFocus(first.id); integrationId = first.id } }
        else { integrationId = nil }
    }

    /// Two-finger swipe left/right on the trackpad flips between Team and Tools.
    private func startSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            if e.phase == .began { swipe = 0 }
            if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) {
                swipe += e.scrollingDeltaX
                if swipe < -40, !showTools { setTools(true); swipe = 0 }
                else if swipe > 40, showTools { setTools(false); swipe = 0 }
            }
            return e
        }
    }

    @ViewBuilder private var leftCard: some View {
        if store.offline {
            VStack(alignment: .leading, spacing: 4) {
                Text("Colony isn't running").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Text("Start it with the `colony` command.").font(.system(size: 12)).foregroundColor(Color(hex: "#8A8F98"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if let a = focus {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: a.color)).frame(width: 7, height: 7)
                    Text(a.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    Text(store.workspaceName).font(.system(size: 12)).foregroundColor(Color(hex: "#8A8F98"))
                }
                Text(a.model).font(.system(size: 11.5)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1)
                Text(statusLine(for: a)).font(.system(size: 12)).foregroundColor(Color(hex: "#B9BDC4")).lineLimit(2)
                Spacer(minLength: 0)
                Button { openChat(room: a.id) } label: {
                    Text("Open chat").font(.system(size: 12, weight: .medium)).foregroundColor(Color(hex: a.color))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Text("Loading team…").font(.system(size: 12)).foregroundColor(Color(hex: "#8A8F98"))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func statusLine(for a: ColonyAgent) -> String {
        if store.activity.active, store.activity.agentName == a.name {
            return store.activity.step.capitalized + "…"
        }
        if store.busyRooms.contains(a.id) { return "Working…" }
        if let last = store.messages.last(where: { !$0.isUser && $0.agentId == a.id }) {
            return DiffEngine.toOneLine(last.text, maxChars: 110)
        }
        return "Idle. Say something in its room."
    }

    /// Pills from Active pills / Integrations. Chat-provider pills (ai_*) are left out: Colony does the chatting.
    private var tools: [AgentTask] {
        state.tasks.filter { $0.isIntegration && !$0.id.hasPrefix("ai_") }
    }

    private var rightCard: some View {
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return VStack(spacing: 4) {
            HStack(spacing: 14) {
                tabButton("Team", on: !showTools) { setTools(false) }
                tabButton("Tools · \(tools.count)", on: showTools) { setTools(true) }
                Spacer()
                if !showTools {
                    // out of the grid: Group chat + 4 agents needed 3 rows and the 4th agent sat below the fold
                    Button { openChat(room: "auto") } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: "#8B8FFB")).frame(width: 6, height: 6)
                            Text("Group chat").font(.system(size: 10.5, weight: .medium)).foregroundColor(Color(hex: "#C9CCFF"))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(hex: "#8B8FFB").opacity(0.16)).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            // two pages side by side; the row slides between them
            GeometryReader { geo in
                HStack(spacing: 0) {
                    page(cols) {
                        ForEach(store.tasks) { t in
                            AgentPill(task: t, state: state, swapping: $swapping) { openChat(room: t.id) }
                        }
                    }
                    .frame(width: geo.size.width)
                    page(cols) {
                        ForEach(tools) { t in
                            AgentPill(task: t, state: state, swapping: $swapping) {
                                state.setFocus(t.id)
                                integrationId = t.id
                            }
                        }
                    } footer: {
                        if tools.isEmpty {
                            Text("Nothing here yet. Tick pills in Settings → Active pills.")
                                .font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079")).padding(.top, 12)
                        }
                    }
                    .frame(width: geo.size.width)
                }
                .offset(x: showTools ? -geo.size.width : 0)
            }
            .clipped()
        }
    }

    private func page<C: View, F: View>(_ cols: [GridItem], @ViewBuilder _ content: () -> C,
                                        @ViewBuilder footer: () -> F = { EmptyView() }) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: cols, spacing: 6) { content() }
            footer()
        }
    }

    private func tabButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundColor(on ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
        }
        .buttonStyle(.plain)
    }

    private func openChat(room: String) {
        store.room = room
        integrationId = nil
        showTools = false
        withAnimation(.easeInOut(duration: 0.2)) { state.view = .prompt }
    }
}

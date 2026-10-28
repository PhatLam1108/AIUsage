import SwiftUI
import WidgetKit

// One screen, nothing behind a click. Top: what needs attention, each with its fix.
// Below: one continuous column per company (Claude, OpenAI, Google), read top to
// bottom as quotas, then money and resets, then the detail, then the heat map.
// The window takes the full height of its screen; the user picks the width. When
// the screen is too short the whole layout is scaled down instead of scrolling.
enum AppLayout {
    static let width: CGFloat = 1300          // default / first-launch width
    static let minWidth: CGFloat = 1040
    static let gap: CGFloat = 14, inset: CGFloat = 16
    static func col(for width: CGFloat) -> CGFloat { (width - inset * 2 - gap * 2) / 3 }
}

struct ContentView: View {
    @State private var store = DashboardStore()
    // Screenshot tooling: AIUSAGE_RANGE=week opens on the 7-day view.
    @State private var range: InsightRange = ProcessInfo.processInfo.environment["AIUSAGE_RANGE"] == "week" ? .week : .day
    @State private var naturalHeight: CGFloat = 0   // layout height with the heat row at its minimum
    @State private var scale: CGFloat = 1           // < 1 only when the screen is too short for even that
    // While the user drags a window edge the layout is frozen at its last size and
    // only scaled; one real layout happens when the drag ends.
    @State private var frozenLayout: CGSize? = nil
    @State private var lastWindowSize: CGSize = .zero
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { geo in
                let live = frozenLayout
                let lw = live?.width ?? geo.size.width / scale
                let lh = live?.height ?? geo.size.height / scale
                let k = live.map { min(geo.size.width / $0.width, geo.size.height / $0.height) } ?? scale
                dashboard(now: context.date, width: lw)
                    .frame(width: lw, height: lh, alignment: .top)
                    // Measure the tightest height this width needs on an invisible copy.
                    .background(alignment: .top) {
                        if live == nil {
                            dashboard(now: context.date, width: lw)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
                        }
                    }
                    .scaleEffect(k, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { lastWindowSize = $0 }
                    .onChange(of: FitKey(avail: geo.size.height, natural: naturalHeight), initial: true) { _, key in
                        guard frozenLayout == nil, key.natural > 200, key.avail > 200 else { return }
                        let fit = min(1, key.avail / key.natural)
                        if abs(fit - k) > 0.004 { scale = max(0.55, fit) }
                    }
            }
        }
        .background(ScreenHugger(onLiveResize: { live in
            frozenLayout = live && lastWindowSize.width > 0
                ? CGSize(width: lastWindowSize.width / scale, height: lastWindowSize.height / scale) : nil
        }))
        .navigationTitle("AI Usage")
        .navigationSubtitle(updatedLine)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Khoảng thời gian", selection: $range) {
                    ForEach(InsightRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help("Khoảng thời gian cho phần phân tích Claude Code và Codex CLI")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.refreshAll() } label: {
                    if store.anyLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.anyLoading)
                .help("Làm mới tất cả nguồn")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "person.crop.circle") }.help("Tài khoản")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(for: .window) { Color.appBG.ignoresSafeArea() }
        .onAppear {
            // First launch: open the Accounts window so the user picks and signs in to their services.
            if !store.config.onboarded { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openSettings() } }
            let last = UserDefaults.standard.double(forKey: "lastWidgetReloadAt")
            if Date().timeIntervalSince1970 - last > 900 {
                WidgetCenter.shared.reloadAllTimelines()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastWidgetReloadAt")
            }
        }
    }

    private var updatedLine: String {
        let times = store.subscriptions.filter(\.live).compactMap(\.fetchedAt) + [store.gemini.fetchedAt].compactMap { $0 }
        guard let t = times.max() else { return String(localized: "Chưa có số liệu") }
        return String(localized: "Cập nhật lúc \(DashboardStore.dayTime.string(from: t))")
    }

    // MARK: Layout

    private func dashboard(now: Date, width: CGFloat) -> some View {
        let col = AppLayout.col(for: width)
        return VStack(spacing: 12) {
            attentionStrip(now: now)
            VStack(spacing: 0) {
                Grid(horizontalSpacing: AppLayout.gap, verticalSpacing: 0) {
                    GridRow {
                        header(store.claude, now: now, refresh: ["claude"]).frame(width: col)
                        header(store.chatgpt, now: now, refresh: ["chatgpt", "codexhist"]).frame(width: col)
                        header(store.agy, now: now, refresh: ["antigravity"]).frame(width: col)
                    }
                    GridRow {
                        claudeQuotas(now: now).frame(width: col)
                        codexQuotas(now: now).frame(width: col)
                        agyQuotas(now: now).frame(width: col)
                    }
                    GridRow {
                        claudeCode.frame(width: col)
                        codexCLI(now: now).frame(width: col)
                        geminiAPI(now: now).frame(width: col)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppLayout.gap) {
                    claudeHourly.frame(width: col)
                    codexDaily.frame(width: col)
                    geminiDaily.frame(width: col)
                }
                .frame(maxHeight: .infinity)
            }
            .background(alignment: .top) {
                HStack(spacing: AppLayout.gap) {
                    columnPanel(.claude)
                    columnPanel(.openai)
                    columnPanel(.geminiBlue)
                }
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, AppLayout.inset)
        .padding(.bottom, 16)
        .frame(width: width)
    }

    /// One company's column: a single surface with a faint brand wash at the top.
    private func columnPanel(_ brand: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.cardBG)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [brand.opacity(0.11), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22)))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
    }

    /// A block inside a column, separated from the one above by a hairline.
    private func section<Content: View, Mark: View>(_ title: LocalizedStringKey?, note: String? = nil,
                                                    @ViewBuilder mark: () -> Mark,
                                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 7) {
                    mark()
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 6)
                    if let note { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, 16) }
    }

    private func section<Content: View>(_ title: LocalizedStringKey?, note: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        section(title, note: note, mark: { EmptyView() }, content: content)
    }

    // MARK: Attention strip

    @ViewBuilder private func attentionStrip(now: Date) -> some View {
        let items = store.attention(now: now)
        if items.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Mọi thứ ổn: không hạn mức nào sắp chạm trần, số liệu đều mới.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardBG))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
        } else {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: min(items.count, 3))
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(items.prefix(6)) { attentionCard($0) }
            }
        }
    }

    private func attentionCard(_ a: Attention) -> some View {
        HStack(spacing: 11) {
            Image(systemName: a.icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(a.tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(a.tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(a.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if let action = a.action, let title = a.actionTitle {
                Button(title) { perform(action) }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(busy(action))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.cardBG))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(a.level == .info ? Color.hairline : a.tint.opacity(0.45), lineWidth: 1)
        )
        .help(a.title + "\n" + a.detail)
    }

    private func busy(_ a: Attention.Action) -> Bool {
        switch a {
        case .refresh(let id, _): return store.loading.contains(id)
        case .loginClaude: return store.loading.contains("claude")
        case .loginGoogle: return store.loading.contains("gemini-login")
        case .codexReset: return store.loading.contains("codex-reset")
        case .claudeReset: return store.loading.contains("claude-reset")
        default: return false
        }
    }

    private func perform(_ a: Attention.Action) {
        switch a {
        case .refresh(let id, _): store.refresh(id)
        case .loginClaude: store.loginClaude()
        case .loginGoogle: store.loginGoogle()
        case .codexReset: store.useCodexReset()
        case .claudeReset: store.openClaudeResets()
        case .accounts, .open: openSettings()
        }
    }

    // MARK: Column headers

    private func header(_ p: ProviderData, now: Date, refresh ids: [String]) -> some View {
        let loading = ids.contains { store.loading.contains($0) }
        return HStack(spacing: 8) {
            ProviderMark(logo: p.logo, color: p.color, size: 13)
            Text(p.id == "chatgpt" ? "ChatGPT" : p.name).font(.system(size: 16, weight: .semibold))
            PlanBadge(tier: p.plan, color: p.color, fontSize: 8.5)
            Spacer(minLength: 6)
            if p.live, isStaleFetch(p.fetchedAt, asOf: now) {
                StaleBadge(fetchedAt: p.fetchedAt, fontSize: 10.5)
            } else if p.live, let t = p.fetchedAt {
                Text(Self.clock.string(from: t)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                    .help("Lần lấy số liệu gần nhất")
            }
            Button { ids.forEach(store.refresh) } label: {
                if loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(loading || !p.enabled)
            .help("Làm mới \(p.name)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    private static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .current; return f }()
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d/M"; f.timeZone = .current; return f }()

    // MARK: Quotas

    private static let tileGrid = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    /// The quota block of a subscription, or why there is none.
    @ViewBuilder private func quotas<Extra: View>(_ p: ProviderData, now: Date, extraTiles: [(BarItem, [String])] = [],
                                                  login: (() -> Void)? = nil, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !p.enabled {
                NotConnected(text: "Nguồn này đang tắt trong cửa sổ Tài khoản.")
            } else if p.needsLogin {
                Text("Phiên đăng nhập đã hết hạn nên số liệu không cập nhật.").font(.system(size: 12)).foregroundStyle(.secondary)
                if let login {
                    Button(action: login) {
                        Label(store.loading.contains(p.id) ? "Đang chờ đăng nhập" : "Đăng nhập lại", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.glassProminent).tint(p.color).disabled(store.loading.contains(p.id))
                } else {
                    NotConnected(text: "Đăng nhập lại trong cửa sổ Tài khoản.")
                }
            } else if !p.hasData {
                NotConnected(text: "Chưa có số liệu. Đăng nhập trong cửa sổ Tài khoản.")
            } else {
                LazyVGrid(columns: Self.tileGrid, spacing: 8) {
                    ForEach(p.bars.filter { $0.window > 0 }) { QuotaTile(bar: $0, color: p.color, now: now) }
                    ForEach(extraTiles, id: \.0.id) { QuotaTile(bar: $0.0, color: p.color, now: now, footer: $0.1) }
                }
                if let s = paceStatus(p.bars.map(\.paceInput), now: now) { PaceStatusLine(status: s, fontSize: 11.5) }
                extra()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func claudeQuotas(now: Date) -> some View {
        var extra: [(BarItem, [String])] = []
        if let api = store.claudeAPI {
            let used = Int((100 * (api.grant - api.balance) / api.grant).rounded())
            extra.append((BarItem(String(localized: "API credit"), min(100, max(0, used)), window: 0,
                                  valueText: usd(api.balance), note: String(localized: "trên \(usd(api.grant))")),
                          [api.spendMonth.map { String(localized: "Chi tháng này \(usd($0))") } ?? " ",
                           String(localized: "Cấp lại khi gia hạn Max")]))
        }
        return quotas(store.claude, now: now, extraTiles: extra, login: store.loginClaude) {
            if store.claudeResets > 0 {
                resetLine(count: store.claudeResets, color: .claude,
                          detail: String(localized: "Dùng trên trang usage của claude.ai"),
                          button: String(localized: "Mở trang reset"), enabled: true, loading: store.loading.contains("claude-reset")) {
                    store.openClaudeResets()
                }
            }
        }
    }

    private func codexQuotas(now: Date) -> some View {
        let r = store.codexHist.resets
        let credits = r.credits.filter(\.available).sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
        return quotas(store.chatgpt, now: now) {
            VStack(alignment: .leading, spacing: 8) {
                if r.available > 0 {
                    resetLine(count: r.available, color: .openai,
                              detail: r.usableNow > 0 ? String(localized: "Dùng được ngay") : String(localized: "Chỉ dùng được khi chạm giới hạn"),
                              button: String(localized: "Dùng lượt reset"), enabled: r.usableNow > 0,
                              loading: store.loading.contains("codex-reset")) { store.useCodexReset() }
                    ForEach(credits) { cr in creditRow(cr, now: now) }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "ticket").foregroundStyle(.secondary)
                        Text("Hết lượt reset").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                Text(String(localized: "30 ngày qua: được cấp \(r.granted30d), đã dùng \(r.used30d)")
                     + (r.lastUsed.map { ", " + String(localized: "lần gần nhất \(Self.day.string(from: $0))") } ?? ""))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                if let m = store.resetMessage { Text(m).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.tileBG))
        }
    }

    private func agyQuotas(now: Date) -> some View {
        quotas(store.agy, now: now) { EmptyView() }
    }

    /// "N lượt reset" with the button to spend one. Hidden by the caller when there are none.
    private func resetLine(count: Int, color: Color, detail: String, button: String, enabled: Bool, loading: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "ticket.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text("Còn \(count) lượt reset").font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button(action: action) {
                HStack(spacing: 4) {
                    if loading { ProgressView().controlSize(.mini) }
                    Text(button)
                }
            }
            .buttonStyle(.glass).controlSize(.small)
            .disabled(!enabled || loading)
        }
    }

    private func creditRow(_ cr: CodexCredit, now: Date) -> some View {
        let soon = cr.expires.map { $0.timeIntervalSince(now) < 3 * 86400 } ?? false
        return HStack(spacing: 6) {
            Text(cr.expires.map { String(localized: "Hết hạn \(DashboardStore.dayTime.string(from: $0))") } ?? cr.title)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if let e = cr.expires, e > now {
                Text(String(localized: "còn \(shortCountdown(to: e, from: now))"))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(soon ? Color.orange : Color.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill((soon ? Color.orange : Color.secondary).opacity(0.14)))
            }
        }
        .help(cr.title)
    }

    // MARK: Claude Code

    private var side: InsightSide { range == .day ? store.insights.day : store.insights.week }

    private var claudeCode: some View {
        section("Claude Code", note: side.requests > 0 ? String(localized: "\(side.requests) request, \(side.sessions) phiên") : nil,
                mark: { Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.claude) }) {
            if !store.config.providers.insights {
                NotConnected(text: "Phân tích Claude Code đang tắt.")
            } else if side.requests == 0 {
                EmptyNote(text: range == .day ? "Không có phiên Claude Code nào trong 24 giờ qua." : "Không có phiên Claude Code nào trong 7 ngày qua.")
            } else {
                Text("Điều gì đang ăn quota").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                driver(side.longSession, "từ phiên chạy liên tục 8 giờ trở lên", String(localized: "Phiên dài và phiên chạy nền cộng dồn rất nhanh."))
                driver(side.bigContext, "ở context trên 150k token", String(localized: "Dùng /compact giữa chừng, /clear khi đổi việc."))
                driver(side.subagentHeavy, "từ phiên dùng nhiều subagent",
                       side.subagents.isEmpty ? String(localized: "Không chạy subagent nào.")
                       : side.subagents.prefix(2).map { "\($0.name) \($0.pct)%" }.joined(separator: ", "))
                Divider().padding(.vertical, 2)
                ForEach(side.models.prefix(3)) { ShareRow(name: $0.name, pct: $0.pct, color: .claude) }
                ForEach(side.projects.prefix(3)) { ShareRow(name: $0.name, pct: $0.pct, color: .claude.opacity(0.6)) }
                Text(sourcesLine).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    .help("Ước tính từ các phiên Claude Code; không gồm chat trên claude.ai.")
            }
        }
    }

    private var sourcesLine: String {
        let hosts = store.insights.remote.map { h in
            h.ok ? h.host : h.host + " (" + String(localized: "số cũ") + (h.at.map { " " + Self.clock.string(from: $0) } ?? "") + ")"
        }
        return String(localized: "Nguồn: ") + ([String(localized: "máy này")] + hosts).joined(separator: ", ")
    }

    private func driver(_ pct: Int, _ title: LocalizedStringKey, _ hint: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(pct)%")
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .foregroundStyle(pct >= 50 ? Color.claude : Color.secondary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var claudeHourly: some View {
        let data = store.insights.hourly
        let byHour = Dictionary(data.map { (Int($0.hour) ?? 0, $0.pct) }, uniquingKeysWith: { a, _ in a })
        let current = Int(data.last?.hour ?? "") ?? -1
        let peak = data.max { $0.pct < $1.pct }
        let rows: [(String, [HeatCell?])] = stride(from: 0, to: 24, by: 6).map { start in
            ("\(start)-\(start + 5)h", (start..<start + 6).map { h in
                let v = byHour[h] ?? 0
                return HeatCell(label: "\(h)h", value: v,
                                valueText: v <= 0 ? nil : String(format: v >= 10 ? "%.0f%%" : "%.1f%%", v),
                                help: "\(h)h: " + String(format: "%.1f%%", v), isNow: h == current)
            })
        }
        return section("Claude theo giờ", note: peak.map { $0.pct > 0 ? String(localized: "cao nhất \($0.hour)h, \(Int($0.pct.rounded()))%") : String(localized: "24 giờ qua") }) {
            if store.config.providers.insights { HeatGrid(rows: rows, header: nil, color: .claude, labelWidth: 46) }
        }
    }

    // MARK: Codex CLI

    private func codexCLI(now: Date) -> some View {
        let c = range == .day ? store.insights.codexDay : store.insights.codexWeek
        let five = store.codexHist.periods.filter { !$0.weekly }
        let capped = five.filter { $0.pct >= 99.5 }.count
        return section("Codex CLI", note: c.turns > 0 ? String(localized: "\(c.sessions) phiên, \(c.responses) phản hồi") : nil,
                       mark: { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.openai) }) {
            if !store.config.providers.codex {
                NotConnected(text: "Codex đang tắt.")
            } else {
                if c.turns == 0 {
                    EmptyNote(text: store.insights.codexAny ? (range == .day ? "Chưa có lượt nào trong 24 giờ qua." : "Chưa có lượt nào trong 7 ngày qua.")
                                                            : "Chưa thấy Codex CLI trên máy này.")
                } else {
                    HStack(spacing: 8) {
                        Metric(value: "\(c.turns)", label: String(localized: "lượt"), size: 18)
                        Metric(value: tokens(c.tokens), label: String(localized: "token"), size: 18)
                        Metric(value: "\(c.peakContext)%", label: String(localized: "context max"), size: 18)
                        Metric(value: durationLabel(c.avgTurnSec), label: String(localized: "mỗi lượt"), size: 18)
                    }
                    StackedBar(parts: [("input", c.tokInput, .openai), ("cache", c.tokCached, Color.openai.opacity(0.4)),
                                       ("output", c.tokOutput, .orange), ("reasoning", c.tokReasoning, Color.orange.opacity(0.45))])
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "\(c.done) lượt xong, \(c.failed) lỗi, \(c.interrupted) bị ngắt, \(c.commands) lệnh shell, \(c.fileChanges) file sửa"))
                            .foregroundStyle(c.failed > max(1, c.done / 4) ? Color.orange : Color.secondary)
                        if !c.sources.isEmpty {
                            Text(String(localized: "Nguồn: ") + c.sources.prefix(3).map { "\($0.name) \($0.pct)%" }.joined(separator: ", "))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.85)
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Các khung 5 giờ gần đây").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    Spacer()
                    if !five.isEmpty {
                        Text(String(localized: "chạm trần \(capped)/\(five.count) lần, 7 ngày")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                if five.isEmpty { EmptyNote(text: "Chưa có dữ liệu.") }
                ForEach(five.prefix(4)) { periodRow($0, now: now) }
            }
        }
    }

    private func periodRow(_ p: CodexPeriod, now: Date) -> some View {
        let f = DateFormatter(); f.timeZone = .current; f.dateFormat = "d/M HH:mm"
        let t = DateFormatter(); t.timeZone = .current; t.dateFormat = "HH:mm"
        let live = p.end > now
        return HStack(spacing: 8) {
            Text("\(f.string(from: p.start)) - \(t.string(from: p.end))")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(live ? Color.primary : Color.secondary)
                .frame(width: 118, alignment: .leading).lineLimit(1)
            UsageBar(value: min(100, Int(p.pct.rounded())), color: p.pct >= 99.5 ? .red : .openai, height: 5)
            Text(String(format: p.pct >= 100 ? "%.0f%%" : "%.1f%%", p.pct))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(p.pct >= 99.5 ? Color.red : Color.primary)
                .frame(width: 46, alignment: .trailing)
        }
        .help(p.models.map { "\($0.0): \(String(format: "%.1f", $0.1))%" }.joined(separator: "\n")
              + "\n" + p.surfaces.map { "\(surfaceName($0.0)) \(String(format: "%.1f", $0.1))%" }.joined(separator: ", "))
    }

    private var codexDaily: some View {
        let days = store.codexHist.daily
        var totals: [String: Double] = [:]
        for d in days { for (m, v) in d.models { totals[m, default: 0] += v } }
        let all = max(0.0001, totals.values.reduce(0, +))
        let top = totals.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        let today = days.last?.day
        let rows: [(String, [HeatCell?])] = top.map { m in
            (shortModel(m), days.map { d in
                let share = 100 * (d.models[m] ?? 0) / all
                return HeatCell(label: "", value: d.models[m] ?? 0, valueText: share < 0.5 ? nil : "\(Int(share.rounded()))%",
                                help: "\(m), \(dayLabel(d.day)): \(Int(share.rounded()))%", isNow: d.day == today)
            })
        }
        return section("Codex theo ngày và model", note: String(localized: "% trên tổng 7 ngày")) {
            if rows.isEmpty { EmptyNote(text: "Chưa có dữ liệu. Bấm làm mới.") }
            else { HeatGrid(rows: rows, header: days.map { dayLabel($0.day) }, color: .openai, labelWidth: 60) }
        }
    }

    // MARK: Gemini API

    private func geminiAPI(now: Date) -> some View {
        let g = store.gemini
        let lag = g.exact && (g.exactThrough.map { $0 < localDay(now) } ?? true)
        return section("Gemini API", note: g.present ? (g.exact ? (lag ? String(localized: "chính xác tới \(dayLabel(g.exactThrough))") : String(localized: "số chính xác")) : String(localized: "ước tính")) : nil,
                       mark: { GeminiMark(size: 17) }) {
            if !store.config.providers.gemini {
                NotConnected(text: "Đang tắt. Bật và nhập khoá service account trong cửa sổ Tài khoản (có hướng dẫn từng bước).")
            } else if !g.present {
                NotConnected(text: "Chưa có số liệu. Kiểm tra khoá service account trong cửa sổ Tài khoản.")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(g.balance.map(money) ?? "–").font(.system(size: 25, weight: .semibold).monospacedDigit())
                            if let t = g.tier { PlanBadge(tier: t, color: .geminiBlue, fontSize: 8) }
                        }
                        Text(g.balanceStale ? "Số dư credit, số cũ" : "Số dư credit").font(.system(size: 10.5))
                            .foregroundStyle(g.balanceStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(g.runway.map { $0 > 999 ? "999+" : "\($0)" } ?? "–").font(.system(size: 19, weight: .semibold).monospacedDigit())
                            .foregroundStyle((g.runway ?? 999) < 7 ? Color.red : (g.runway ?? 999) < 21 ? Color.orange : Color.primary)
                        Text("ngày còn đủ").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .help("Số dư chia cho mức chi trung bình 7 ngày")
                }
                if g.needsLogin {
                    Button { store.loginGoogle() } label: { Label("Đăng nhập Google AI Studio", systemImage: "person.crop.circle.badge.checkmark") }
                        .buttonStyle(.glass).controlSize(.small).disabled(store.loading.contains("gemini-login"))
                }
                HStack(spacing: 8) {
                    Metric(value: money(g.today), label: lag || !g.exact ? String(localized: "hôm nay, ước tính") : String(localized: "hôm nay"), size: 15)
                    Metric(value: money(g.week), label: String(localized: "7 ngày"), size: 15)
                    Metric(value: money(g.month), label: String(localized: "tháng này"), size: 15)
                }
                .help("Chi phí ước tính từ token nhân bảng giá Google, có thể cao hơn AI Studio khoảng 10% vì token cache. Số chính xác lấy từ Billing export khi có.")
                Text(String(localized: "Cuối tháng khoảng \(money(g.projectedMonth)), trung bình \(money(g.perDay))/ngày")
                     + (g.aistudioMonth.map { ". " + String(localized: "AI Studio báo \(money($0))") } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let cap = g.tierCap, cap > 0 {
                    VStack(alignment: .leading, spacing: 3) {
                        UsageBar(value: min(100, Int(g.month / cap * 100)), color: .geminiBlue, height: 4)
                        Text("\(money(g.month)) / \(money(cap)) để lên tier kế tiếp").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                Divider().padding(.vertical, 2)
                let spent = g.models.filter(\.priced).reduce(0) { $0 + $1.cost }
                ForEach(g.models.prefix(3)) { m in
                    ShareRow(name: m.id.replacingOccurrences(of: "gemini-", with: ""),
                             pct: spent > 0 && m.priced ? Int((100 * m.cost / spent).rounded()) : 0, color: .geminiPurple,
                             detail: String(localized: "\(m.requests) req, \(tokens(m.input)) vào, \(tokens(m.output)) ra, \(m.priced ? money(m.cost) : String(localized: "chưa có giá"))"))
                }
            }
        }
    }

    // 30 days as a Monday-first calendar.
    private var geminiDaily: some View {
        let data = store.gemini.daily
        let total = data.reduce(0) { $0 + $1.cost }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let lead = data.first.flatMap { f.date(from: $0.day) }.map { (cal.component(.weekday, from: $0) + 5) % 7 } ?? 0
        let today = data.last?.day
        var cells: [HeatCell?] = Array(repeating: nil, count: lead)
        for d in data {
            cells.append(HeatCell(label: "\(Int(d.day.suffix(2)) ?? 0)", value: d.cost,
                                  valueText: d.cost <= 0 ? nil : d.cost >= 1000 ? String(format: "%.1fk", d.cost / 1000)
                                      : d.cost >= 10 || d.cost == d.cost.rounded() ? "\(Int(d.cost.rounded()))" : String(format: "%.2f", d.cost),
                                  help: "\(dayLabel(d.day)): \(money(d.cost))", isNow: d.day == today))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        let rows: [(String, [HeatCell?])] = stride(from: 0, to: cells.count, by: 7).map { ("", Array(cells[$0..<$0 + 7])) }
        return section("Gemini theo ngày", note: data.isEmpty ? nil : String(localized: "30 ngày, \(money(total))")) {
            if store.config.providers.gemini && !data.isEmpty {
                HeatGrid(rows: rows, header: [String(localized: "T2"), String(localized: "T3"), String(localized: "T4"), String(localized: "T5"),
                                              String(localized: "T6"), String(localized: "T7"), String(localized: "calendar.sun", defaultValue: "CN", comment: "Sunday column of the spending calendar")],
                         color: .geminiPurple)
            }
        }
    }
}

enum InsightRange: String, CaseIterable, Identifiable {
    case day, week
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .day ? "24 giờ" : "7 ngày" }
}

private struct FitKey: Equatable { let avail: CGFloat; let natural: CGFloat }

#Preview {
    ContentView()
}

// MARK: - Window sizing

// MARK: - Window sizing

// Pins the window's height to the content's real height. SwiftUI's contentSize
// resizability over-allocated with the hidden title bar and clamped our
// corrections back, so we size the NSWindow ourselves.
/// Pins the window to the full visible height of whatever screen it is on
/// (menu bar to Dock; whole screen when the Dock is hidden or elsewhere) and
/// lets the user choose the width. Re-pins when the window moves to another
/// screen or the Dock/menu bar changes the visible area.
private struct ScreenHugger: NSViewRepresentable {
    var onLiveResize: (Bool) -> Void = { _ in }

    final class Coordinator {
        weak var window: NSWindow?
        var onLiveResize: (Bool) -> Void = { _ in }
        var observers: [NSObjectProtocol] = []

        func attach(_ win: NSWindow) {
            guard window !== win else { return }
            window = win
            win.styleMask.insert(.resizable)
            let nc = NotificationCenter.default
            // Full height on launch and whenever the window lands on another
            // screen / the Dock changes; after that the user may drag both edges.
            observers = [NSWindow.didChangeScreenNotification, NSWindow.didEndLiveResizeNotification].map { name in
                nc.addObserver(forName: name, object: win, queue: .main) { [weak self] n in
                    if n.name == NSWindow.didEndLiveResizeNotification, let w = self?.window {
                        UserDefaults.standard.set(Double(w.frame.width), forKey: "dashboardWidth")
                        self?.pin(fullHeight: false)
                    } else {
                        self?.pin(fullHeight: true)
                    }
                }
            }
            observers.append(nc.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: win, queue: .main) { [weak self] _ in
                self?.onLiveResize(true)
            })
            observers.append(nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: win, queue: .main) { [weak self] _ in
                self?.onLiveResize(false)
            })
            observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.pin(fullHeight: true) })
            let saved = UserDefaults.standard.double(forKey: "dashboardWidth")
            pin(width: saved > 0 ? CGFloat(saved) : AppLayout.width, fullHeight: true)
            // macOS places a new window after this first pass — pin again once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.pin(fullHeight: true) }
        }

        func pin(width: CGFloat? = nil, fullHeight: Bool) {
            DispatchQueue.main.async { [weak self] in   // never setFrame inside a display cycle
                guard let win = self?.window, let vis = (win.screen ?? NSScreen.main)?.visibleFrame else { return }
                let chrome = win.frame.height - win.contentLayoutRect.height
                win.contentMinSize = NSSize(width: min(AppLayout.minWidth, vis.width), height: min(560, vis.height - chrome))
                win.contentMaxSize = NSSize(width: vis.width, height: vis.height - chrome)
                var f = win.frame
                f.size.width = min(max(width ?? f.width, min(AppLayout.minWidth, vis.width)), vis.width)
                if fullHeight {
                    f.size.height = vis.height
                    f.origin.y = vis.minY
                } else {
                    f.size.height = min(f.height, vis.height)
                    if f.minY < vis.minY { f.origin.y = vis.minY }
                    if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.height }
                }
                if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
                if f.minX < vis.minX { f.origin.x = vis.minX }
                if f != win.frame { win.setFrame(f, display: true, animate: false) }
            }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onLiveResize = onLiveResize
        DispatchQueue.main.async { if let win = nsView.window { context.coordinator.attach(win) } }
    }
}

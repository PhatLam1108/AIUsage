import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Data Models

struct BarData: Identifiable {
    let id: String
    let label: String
    let value: Int               // % used; -1 = not reported
    let color: Color?
    let useGradient: Bool
    let resetDate: Date?
    let short: String            // name used by the pace status line
    let window: TimeInterval     // quota window length, for the pace tick; 0 = no pace, no countdown
    var valueText: String? = nil // replaces the percentage (API credit shows dollars left)

    init(label: String, value: Int, color: Color? = nil, useGradient: Bool = false, resetDate: Date? = nil,
         short: String? = nil, window: TimeInterval = QuotaWindow.week, valueText: String? = nil) {
        self.id = label; self.label = label; self.value = value
        self.color = color; self.useGradient = useGradient; self.resetDate = resetDate
        self.short = short ?? label; self.window = window; self.valueText = valueText
    }
    var paceInput: PaceInput { PaceInput(short: short, value: value, reset: resetDate, window: window) }
}

/// One Antigravity account, a column of the account table.
struct AccountColumn: Identifiable {
    let id: String
    let label: String
    let bars: [BarData]          // Gemini 5h, Gemini week
    var note: String? = nil      // instead of numbers: signed out, no data yet
    var fetchedAt: Date? = nil
}

struct ProviderInfo: Identifiable {
    let id: String
    let name: String
    let badge: String
    let provider: String
    let color: Color
    let bars: [BarData]
    let resetDate: Date?
    var needsLogin: Bool = false
    var fetchedAt: Date? = nil   // this provider's last successful fetch
    var state: SourceState = .ok
    /// Antigravity with extra accounts: every account, the signed-in one first.
    var accounts: [AccountColumn] = []
    /// Claude: API credit balance, shown beside the plan badge instead of as a tile.
    var credit: String? = nil
}

/// Whether a provider card has numbers to show.
enum SourceState { case ok, noData, off }

/// The user's real home folder. The widget is sandboxed, so NSHomeDirectory() is
/// its container; the password database still knows the real one (it may not be /Users/<name>).
let realHome: String = {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
    return "/Users/" + NSUserName()
}()

struct UsageEntry: TimelineEntry {
    let date: Date
    let providers: [ProviderInfo]
    var updatedAt: Date? = nil   // cache's updated_at — when data was last fetched
}

// Brand colors, SVG logos, BrandIcon/PlanBadge/UsageBar live in Shared.swift.

// MARK: - Refresh Intent

struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh AI Usage"
    static var description: IntentDescription = "Fetch latest AI usage data"
    // Run in-place (do NOT open the app). The sandboxed widget can't spawn the
    // fetch itself, so it just drops a trigger file; a LaunchAgent watching that
    // file runs the fetch in the background and reloads the widget.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Fire-and-forget: write the trigger and return immediately. The watching
        // LaunchAgent fetches all providers and reloads the widget when the cache
        // is fresh (ai_usage_refresh.sh ends with `AIUsage --reload-widget`).
        // perform() must stay short — long-polling here kept the invalidated
        // (shimmering) state alive for ~24s and the system re-rendered it over
        // and over, which looked like the widget was flashing in a loop.
        let path = realHome + "/Library/Caches/ai_usage.trigger"
        let stamp = "\(Date().timeIntervalSince1970)"
        try? stamp.write(toFile: path, atomically: true, encoding: .utf8)
        return .result()
    }
}

struct LoginClaudeIntent: AppIntent {
    static var title: LocalizedStringResource = "Đăng nhập lại Claude"
    static var description: IntentDescription = "Mở cửa sổ đăng nhập claude.ai"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Drop a login trigger; a LaunchAgent watching it opens the login window
        // (the widget extension is sandboxed and can't launch a GUI helper itself).
        let path = realHome + "/Library/Caches/ai_usage_login.trigger"
        let stamp = "\(Date().timeIntervalSince1970)"
        try? stamp.write(toFile: path, atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return .result()
    }
}

// MARK: - Timeline Provider

struct UsageProvider: TimelineProvider {

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), providers: sampleData())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // Emit one entry per minute (same data, re-rendered each minute) so the
        // reset countdowns tick down on their own. New numbers arrive through the
        // refresh job, which reloads the widget right after each fetch; the reload
        // after 15 min here is only the fallback if that job is not running.
        let base = loadEntry()
        let now = Date()
        var entries: [UsageEntry] = []
        for i in 0..<16 {
            let d = Calendar.current.date(byAdding: .minute, value: i, to: now)!
            entries.append(UsageEntry(date: d, providers: base.providers, updatedAt: base.updatedAt))
        }
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now)!
        let resets = base.providers.flatMap { $0.bars.compactMap(\.resetDate) + $0.accounts.flatMap { $0.bars.compactMap(\.resetDate) } }
            .filter { $0 > now && $0 < next }
        for r in Set(resets) {
            entries.append(UsageEntry(date: r.addingTimeInterval(1), providers: base.providers, updatedAt: base.updatedAt))
        }
        entries.sort { $0.date < $1.date }
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    private func loadEntry() -> UsageEntry {
        let realPath = realHome + "/.ai_usage_cache.json"
        let tmpPath = "/tmp/ai_usage_cache.json"
        let fileData = (try? Data(contentsOf: URL(fileURLWithPath: realPath)))
                    ?? (try? Data(contentsOf: URL(fileURLWithPath: tmpPath)))
        // No cache yet (fresh install): every card says "not connected" rather than inventing numbers.
        let json = fileData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        // Sources switched off in the app's Accounts window (config.json "providers").
        let cfgData = try? Data(contentsOf: URL(fileURLWithPath: realHome + "/Library/Application Support/AIUsage/config.json"))
        let switches = (cfgData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["providers"] as? [String: Any] ?? [:]
        func state(_ key: String, has: Bool) -> SourceState {
            if switches[key] as? Bool == false { return .off }
            return has ? .ok : .noData
        }
        let updatedAt = parseISODate(json["updated_at"] as? String)
        let c  = json["claude"] as? [String: Any] ?? [:]
        let cx = json["codex"]  as? [String: Any] ?? [:]
        let g  = json["agy"]    as? [String: Any] ?? [:]

        let claudePlan = c["plan"]  as? String ?? "MAX"
        let codexPlan  = cx["plan"] as? String ?? "PLUS"
        let gemPlan    = g["plan"]  as? String ?? "AI PRO"

        let claudeReset       = parseISODate(c["session_reset"] as? String)
        let claudeWeeklyReset = parseISODate(c["weekly_reset"]  as? String)
        let codexReset        = parseISODate(cx["session_reset"] as? String)
        let codexWeeklyReset  = parseISODate(cx["weekly_reset"]  as? String)

        func agyBars(_ g: [String: Any], version: Bool) -> [BarData] {
            // Model versions come from the fetched data so labels auto-track renames.
            // Empty string is NOT a valid version (?? only catches nil) — guard it.
            let ver = (g["gemini_ver"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let gem = version && ver != nil ? "Gemini \(ver!)" : "Gemini"
            return [
                BarData(label: String(localized: "\(gem) · 5 giờ"), value: g["gemini_5h"] as? Int ?? 0, useGradient: true,
                        resetDate: parseISODate(g["gemini_5h_reset"] as? String),
                        short: String(localized: "Gemini 5 giờ"), window: QuotaWindow.fiveHours),
                BarData(label: String(localized: "\(gem) · tuần"), value: g["gemini_weekly"] as? Int ?? 0, useGradient: true,
                        resetDate: parseISODate(g["gemini_weekly_reset"] as? String),
                        short: String(localized: "Gemini tuần")),
                // No Claude/GPT here: almost never used, and the room goes to a third account.
            ]
        }
        // Extra Antigravity accounts (config.json "agy_accounts", cache "agy_<id>").
        func column(_ g: [String: Any], id: String, name: String, fallback: String) -> AccountColumn {
            let email = g["email"] as? String ?? ""
            // The part before "@" only: the name column is narrow.
            let raw = !name.isEmpty ? name : email
            let label = raw.isEmpty ? fallback : String(raw.split(separator: "@").first ?? Substring(raw))
            let note: String? = g["needs_login"] as? Bool == true ? String(localized: "cần đăng nhập")
                : (g["gemini_weekly"] == nil && g["gemini_5h"] == nil) ? String(localized: "chưa có số") : nil
            return AccountColumn(id: id, label: label, bars: agyBars(g, version: false), note: note,
                                 fetchedAt: parseISODate(g["fetched_at"] as? String))
        }
        let cfg = cfgData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let extra = (cfg["agy_accounts"] as? [[String: Any]] ?? []).enumerated().compactMap { i, a -> AccountColumn? in
            guard let id = a["id"] as? String else { return nil }
            return column(json["agy_" + id] as? [String: Any] ?? [:], id: id, name: a["name"] as? String ?? "",
                          fallback: String(localized: "Tài khoản \(i + 2)"))
        }
        let accounts = extra.isEmpty ? [] : [column(g, id: "main", name: "", fallback: String(localized: "Chính"))] + extra

        // No "session" means the plan has no 5-hour limit (verified Ultra accounts).
        var claudeBars: [BarData] = []
        if let session = c["session"] as? Int {
            claudeBars.append(BarData(label: String(localized: "5 giờ"), value: session, resetDate: claudeReset,
                                      short: String(localized: "5 giờ"), window: QuotaWindow.fiveHours))
        }
        claudeBars.append(BarData(label: String(localized: "Tuần"), value: c["weekly"] as? Int ?? 0, resetDate: claudeWeeklyReset,
                                  short: String(localized: "Tuần")))
        // Per-model weekly limits (claude.ai "weekly_scoped", e.g. Fable).
        for s in c["scoped"] as? [[String: Any]] ?? [] {
            guard let label = s["label"] as? String else { continue }
            claudeBars.append(BarData(label: String(localized: "\(label) · tuần"), value: s["pct"] as? Int ?? 0,
                                      resetDate: parseISODate(s["reset"] as? String) ?? claudeWeeklyReset, short: label))
        }
        // Cloud session credits (remote Claude Code sessions): dollars left of a fixed
        // allowance. The bar is the share spent; no countdown.
        if let cl = c["cloud"] as? [String: Any], let left = (cl["left"] as? NSNumber)?.doubleValue,
           let limit = (cl["limit"] as? NSNumber)?.doubleValue, limit > 0 {
            let used = Int((100 * (limit - left) / limit).rounded())
            claudeBars.append(BarData(label: String(localized: "Phiên cloud"), value: min(100, max(0, used)), short: "Cloud", window: 0,
                                      valueText: "$" + String(format: "%.2f", left)))
        }
        // Anthropic Console (API platform) credit: Max and Ultra grant $200 each month,
        // refilled on renewal. Just the balance, beside the plan badge: a tile for one
        // number that barely moves took a whole row.
        let claudeCredit = (c["api"] as? [String: Any])?["balance"] as? Double

        let agyFetched = ([parseISODate(g["fetched_at"] as? String)] + extra.map(\.fetchedAt)).compactMap { $0 }.min()
        return UsageEntry(date: Date(), providers: [
            ProviderInfo(id: "claude", name: "Claude", badge: claudePlan, provider: "claude", color: .claude, bars: claudeBars,
                         resetDate: claudeReset, needsLogin: c["needs_login"] as? Bool ?? false,
                         fetchedAt: parseISODate(c["fetched_at"] as? String),
                         state: state("claude", has: c["weekly"] != nil || c["needs_login"] as? Bool == true),
                         credit: claudeCredit.map { "$" + String(format: "%.2f", $0) }),
            ProviderInfo(id: "chatgpt", name: "ChatGPT", badge: codexPlan, provider: "openai", color: .openai, bars: [
                BarData(label: String(localized: "5 giờ"), value: cx["session"] as? Int ?? 0, resetDate: codexReset,
                        short: String(localized: "5 giờ"), window: QuotaWindow.fiveHours),
                BarData(label: String(localized: "Tuần"), value: cx["weekly"] as? Int ?? 0, resetDate: codexWeeklyReset,
                        short: String(localized: "Tuần")),
            ], resetDate: codexReset, fetchedAt: parseISODate(cx["fetched_at"] as? String),
               state: state("codex", has: cx["session"] != nil)),
            ProviderInfo(id: "antigravity", name: "Antigravity", badge: gemPlan, provider: "gemini", color: .geminiBlue,
                         bars: agyBars(g, version: true), resetDate: nil,
                         fetchedAt: accounts.isEmpty ? parseISODate(g["fetched_at"] as? String) : agyFetched,
                         state: state("agy", has: g["gemini_weekly"] != nil || g["gemini_5h"] != nil || !extra.isEmpty),
                         accounts: accounts),
        ], updatedAt: updatedAt)
    }

    private func sampleData() -> [ProviderInfo] {
        [
            ProviderInfo(id: "claude", name: "Claude", badge: "MAX", provider: "claude", color: .claude, bars: [
                BarData(label: "5 giờ", value: 72, window: QuotaWindow.fiveHours),
                BarData(label: "Tuần", value: 54),
                BarData(label: "Fable · tuần", value: 21),
            ], resetDate: Date().addingTimeInterval(3600), fetchedAt: Date(), credit: "$186.40"),
            ProviderInfo(id: "chatgpt", name: "ChatGPT", badge: "PLUS", provider: "openai", color: .openai, bars: [
                BarData(label: "5 giờ", value: 33, window: QuotaWindow.fiveHours),
                BarData(label: "Tuần", value: 48),
            ], resetDate: nil, fetchedAt: Date()),
            ProviderInfo(id: "antigravity", name: "Antigravity", badge: "AI PRO", provider: "gemini", color: .geminiBlue, bars: [
                BarData(label: "Gemini · 5 giờ", value: 0, useGradient: true, window: QuotaWindow.fiveHours),
                BarData(label: "Gemini · tuần", value: 1, useGradient: true),
            ], resetDate: Date().addingTimeInterval(7200), fetchedAt: Date()),
        ]
    }
}

// MARK: - Pieces

/// Time to the reset: a live per-second timer in the last hour (system-driven, no
/// timeline reloads), "2d 4h" / "5h 12m" before that, "đang reset" once it has passed.
struct ResetCountdown: View {
    let bar: BarData
    let asOf: Date   // the timeline entry's date

    var body: some View {
        if bar.value >= 0, bar.window > 0, let reset = bar.resetDate {
            if reset <= asOf {
                // Window refilled; the fresh number arrives with the next fetch (<= 5 min).
                Text("đang reset")
            } else if reset.timeIntervalSince(asOf) < 3600 {
                Text(timerInterval: asOf...reset, countsDown: true)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text(compact(reset))
            }
        }
    }

    private func compact(_ date: Date) -> String {
        let secs = max(0, Int(date.timeIntervalSince(asOf)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

/// One quota as a small tile: label and countdown, then the big number beside its bar.
struct QuotaCell: View {
    let bar: BarData
    let color: Color
    let asOf: Date
    var padV: CGFloat = 3.5

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(bar.label).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                ResetCountdown(bar: bar, asOf: asOf)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 7) {
                Text(bar.valueText ?? (bar.value < 0 ? "–" : "\(bar.value)%"))
                    .font(.system(size: 13.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(bar.valueText == nil ? usagePercentColor(bar.value) : .primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(1)
                UsageBar(value: max(0, bar.value), color: bar.color ?? color, gradient: bar.useGradient, height: 5,
                         pace: bar.value >= 0 ? paceFraction(reset: bar.resetDate, window: bar.window, now: asOf) : nil)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, padV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

/// Several Antigravity accounts: one row each (name, Gemini 5h, Gemini week), all drawn
/// the same. Gemini only, see agyBars.
struct AccountTable: View {
    let provider: ProviderInfo
    let asOf: Date
    var rowGap: CGFloat = 4
    private var accounts: [AccountColumn] { provider.accounts }
    private var color: Color { provider.color }

    private var columns: [String] {
        [String(localized: "Gemini 5 giờ"), String(localized: "Gemini tuần")]
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: rowGap) {
            // The card's own header: the logo and plan over the names, then the quotas.
            GridRow {
                HStack(spacing: 5) {
                    BrandIcon(provider: provider.provider, color: color, size: 11)
                    PlanBadge(tier: provider.badge, color: color, fontSize: 7.5)
                }
                .fixedSize()
                ForEach(columns.indices, id: \.self) { i in
                    Text(columns[i]).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(accounts) { a in
                GridRow {
                    // Orange when that account's numbers are old.
                    Text(a.label).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isStaleFetch(a.fetchedAt, asOf: asOf) ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 104, alignment: .leading)
                    if let note = a.note {
                        Text(note).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridCellColumns(columns.count)
                    } else {
                        ForEach(columns.indices, id: \.self) { i in cell(a, i) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ a: AccountColumn, _ i: Int) -> some View {
        if i < a.bars.count {
            let bar = a.bars[i]
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(bar.value < 0 ? "–" : "\(bar.value)%")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(usagePercentColor(bar.value))
                    Spacer(minLength: 1)
                    ResetCountdown(bar: bar, asOf: asOf)
                        .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
                UsageBar(value: max(0, bar.value), color: bar.color ?? color, gradient: bar.useGradient, height: 5,   // same as QuotaCell
                         pace: bar.value >= 0 ? paceFraction(reset: bar.resetDate, window: bar.window, now: asOf) : nil)
            }
            .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

// MARK: - Provider Card (glass)

struct ProviderCard: View {
    let provider: ProviderInfo
    let asOf: Date
    var metrics = WidgetMetrics.compact
    // First card only: the refresh button, INSIDE the header row (an overlay
    // with hard-coded offsets collided with the card when padding changed).
    var showRefresh = false
    var clockText: String? = nil   // fetched-at time (first card, beside the refresh button)

    /// Several accounts: the table carries the header itself (logo, plan, account names).
    private var tableOnly: Bool { provider.state == .ok && !provider.needsLogin && !provider.accounts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tableOnly {
                AccountTable(provider: provider, asOf: asOf, rowGap: metrics.rowGap)
            } else {
            HStack(spacing: 7) {
                BrandIcon(provider: provider.provider, color: provider.color, size: 11)
                Text(provider.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                PlanBadge(tier: provider.badge, color: provider.color, fontSize: 8)
                if let credit = provider.credit, provider.state == .ok {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(credit).font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("credit").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                // No forecast text in the widget: the pace tick on the bars is enough.
                // Stale data is a warning, not commentary, so that badge stays.
                if provider.state == .ok, isStaleFetch(provider.fetchedAt, asOf: asOf) {
                    StaleBadge(fetchedAt: provider.fetchedAt, fontSize: 9.5)
                }
                if showRefresh {
                    // One capsule = fetched-at time + refresh: the time is the
                    // proof the press landed, so they belong together.
                    Button(intent: RefreshUsageIntent()) {
                        HStack(spacing: 4) {
                            if let clockText {
                                Text(clockText).font(.system(size: 10, weight: .medium).monospacedDigit())
                            }
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, clockText == nil ? 6 : 7)
                        .frame(height: 18)
                        .background(
                            Capsule()
                                .fill(Color.appBG.opacity(0.6))
                                .overlay(Capsule().strokeBorder(Color.edgeTop, lineWidth: 0.5))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if provider.state != .ok {
                Text(provider.state == .off ? "Đã tắt trong AIUsage" : "Chưa kết nối · mở AIUsage để đăng nhập")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else if provider.needsLogin {
                Button(intent: LoginClaudeIntent()) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 11))
                        Text("Đăng nhập lại").font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(provider.color.opacity(0.20)))
                    .foregroundStyle(provider.color)
                }
                .buttonStyle(.plain)
            } else {
                TileRows(count: provider.bars.count, spacing: metrics.tileGap) { i in
                    QuotaCell(bar: provider.bars[i], color: provider.color, asOf: asOf, padV: metrics.tilePadV)
                }
            }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, metrics.cardPadV)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: 13, brand: provider.color)
    }
}

// MARK: - Widget View

/// Spacing of the widget. Roomy when the content leaves height to spare (e.g. Claude
/// Ultra with 3 tiles and Antigravity with Gemini rows only), compact otherwise.
struct WidgetMetrics {
    var cardGap: CGFloat = 5, cardPadV: CGFloat = 6, tilePadV: CGFloat = 3.5, tileGap: CGFloat = 5, rowGap: CGFloat = 4
    static let compact = WidgetMetrics()
    static let roomy = WidgetMetrics(cardGap: 6, cardPadV: 7, tilePadV: 4.5, tileGap: 6, rowGap: 5)
    static let spacious = WidgetMetrics(cardGap: 9, cardPadV: 10, tilePadV: 6.5, tileGap: 7, rowGap: 8)
}

struct SidebarWidgetView: View {
    let entry: UsageEntry

    // When the data was last fetched (local time) — the visible proof a refresh landed.
    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone.current
        return f.string(from: entry.updatedAt ?? entry.date)
    }

    var body: some View {
        // The first layout whose height fits wins.
        ViewThatFits(in: .vertical) {
            cards(.spacious)
            cards(.roomy)
            cards(.compact)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(10)   // our only inset — system content margins are disabled
    }

    private func cards(_ m: WidgetMetrics) -> some View {
        VStack(spacing: m.cardGap) {
            ForEach(Array(entry.providers.enumerated()), id: \.element.id) { idx, provider in
                ProviderCard(provider: provider, asOf: entry.date, metrics: m,
                             showRefresh: idx == 0,
                             // Clock = fetched-at of the WHOLE widget, so it sits with the
                             // refresh button, not on a provider it seems to belong to.
                             clockText: idx == 0 ? timeString : nil)
            }
        }
    }
}

// MARK: - Widget Configuration

@main
struct AIUsageWidget: Widget {
    let kind = "AIUsageWidgetV2"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            SidebarWidgetView(entry: entry)
                // NO .invalidatableContent() here: it keeps the widget in the
                // "invalidated" pulsing state from the button press until the
                // next timeline reload (~20s of fetch) — reads as a flash loop.
                // Refresh feedback = the fetched-at clock jumping when data lands.
                .containerBackground(for: .widget) {
                    // Solid deep background with a subtle vertical falloff —
                    // matches the app; no see-through mud over bright desktops.
                    LinearGradient(colors: [Color.appBGTop, Color.appBG],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("AI Usage")
        .description("Claude · ChatGPT · Antigravity usage")
        .supportedFamilies([.systemLarge])
        // Kill the system's ~16pt default margins — cards run near the edge
        // with our own 9pt inset instead.
        .contentMarginsDisabled()
    }
}

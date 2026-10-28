import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Data Models

struct BarData: Identifiable {
    let id: String
    let label: String
    let value: Int
    let color: Color?
    let useGradient: Bool
    let resetDate: Date?
    let short: String            // name used by the pace status line
    let window: TimeInterval     // quota window length, for the pace tick

    init(label: String, value: Int, color: Color? = nil, useGradient: Bool = false, resetDate: Date? = nil,
         short: String? = nil, window: TimeInterval = QuotaWindow.week) {
        self.id = label; self.label = label; self.value = value
        self.color = color; self.useGradient = useGradient; self.resetDate = resetDate
        self.short = short ?? label; self.window = window
    }
    var paceInput: PaceInput { PaceInput(short: short, value: value, reset: resetDate, window: window) }
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
        // reset countdowns tick down on their own, then reload after 5 min.
        let base = loadEntry()
        let now = Date()
        var entries: [UsageEntry] = []
        for i in 0..<6 {
            let d = Calendar.current.date(byAdding: .minute, value: i, to: now)!
            entries.append(UsageEntry(date: d, providers: base.providers, updatedAt: base.updatedAt))
        }
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: now)!
        let resets = base.providers.flatMap { $0.bars.compactMap(\.resetDate) }
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

        let claudePlan = c["plan"]  as? String ?? "MAX 5x"
        let codexPlan  = cx["plan"] as? String ?? "PLUS"
        let gemPlan    = g["plan"]  as? String ?? "AI PRO"

        let claudeReset       = parseISODate(c["session_reset"] as? String)
        let claudeWeeklyReset = parseISODate(c["weekly_reset"]  as? String)
        let codexReset        = parseISODate(cx["session_reset"] as? String)
        let codexWeeklyReset  = parseISODate(cx["weekly_reset"]  as? String)

        // Model versions come from the fetched data so labels auto-track renames.
        // Empty string is NOT a valid version (?? only catches nil) — guard it.
        let gemVerRaw = g["gemini_ver"] as? String
        let gemVer = (gemVerRaw?.isEmpty == false) ? gemVerRaw! : "3.7"
        let gemBars = [
            BarData(label: "Gem \(gemVer) · 5h", value: g["gemini_5h"]     as? Int ?? 0, useGradient: true,
                    resetDate: parseISODate(g["gemini_5h_reset"] as? String),
                    short: "Gem 5 giờ", window: QuotaWindow.fiveHours),
            BarData(label: "Gem \(gemVer) · Wk", value: g["gemini_weekly"] as? Int ?? 0, useGradient: true,
                    resetDate: parseISODate(g["gemini_weekly_reset"] as? String),
                    short: "Gem tuần"),
            BarData(label: "C+G · 5h",     value: g["claude_gpt_5h"]     as? Int ?? 0,
                    resetDate: parseISODate(g["claude_gpt_5h_reset"] as? String),
                    short: "C+G 5 giờ", window: QuotaWindow.fiveHours),
            BarData(label: "C+G · Wk",     value: g["claude_gpt_weekly"] as? Int ?? 0,
                    resetDate: parseISODate(g["claude_gpt_weekly_reset"] as? String),
                    short: "C+G tuần"),
        ]

        var claudeBars = [
            BarData(label: "5-hour",  value: c["session"] as? Int ?? 0, resetDate: claudeReset,
                    short: "5 giờ", window: QuotaWindow.fiveHours),
            BarData(label: "Weekly",  value: c["weekly"]  as? Int ?? 0, resetDate: claudeWeeklyReset, short: "Tuần"),
        ]
        // Per-model weekly limits (claude.ai "weekly_scoped", e.g. Fable).
        for s in c["scoped"] as? [[String: Any]] ?? [] {
            guard let label = s["label"] as? String else { continue }
            claudeBars.append(BarData(label: label, value: s["pct"] as? Int ?? 0,
                                      resetDate: parseISODate(s["reset"] as? String) ?? claudeWeeklyReset, short: label))
        }
        // Anthropic Console (API platform) credit: the Max plan grants $200 of API credit
        // each month, refilled on renewal. Shown as % used with the balance left in the
        // label; window 0 = no pace tick, and the renewal date isn't exposed, so no countdown.
        if let api = c["api"] as? [String: Any], let bal = api["balance"] as? Double {
            let grant = max(api["grant"] as? Double ?? 200, 1)
            let used = Int((100 * (grant - bal) / grant).rounded())
            let fmt = String(format: "%.2f", bal)
            claudeBars.append(BarData(label: "API $\(fmt)", value: min(100, max(0, used)), short: "API", window: 0))
        }

        return UsageEntry(date: Date(), providers: [
            ProviderInfo(id: "claude", name: "Claude", badge: claudePlan, provider: "claude", color: .claude, bars: claudeBars,
                         resetDate: claudeReset, needsLogin: c["needs_login"] as? Bool ?? false,
                         fetchedAt: parseISODate(c["fetched_at"] as? String),
                         state: state("claude", has: c["session"] != nil || c["needs_login"] as? Bool == true)),
            ProviderInfo(id: "chatgpt", name: "ChatGPT", badge: codexPlan, provider: "openai", color: .openai, bars: [
                BarData(label: "5-hour", value: cx["session"] as? Int ?? 0, resetDate: codexReset,
                        short: "5 giờ", window: QuotaWindow.fiveHours),
                BarData(label: "Weekly", value: cx["weekly"]  as? Int ?? 0, resetDate: codexWeeklyReset, short: "Tuần"),
            ], resetDate: codexReset, fetchedAt: parseISODate(cx["fetched_at"] as? String),
               state: state("codex", has: cx["session"] != nil)),
            ProviderInfo(id: "antigravity", name: "Antigravity", badge: gemPlan, provider: "gemini", color: .geminiBlue, bars: gemBars, resetDate: nil,
                         fetchedAt: parseISODate(g["fetched_at"] as? String),
                         state: state("agy", has: g["gemini_weekly"] != nil || g["gemini_5h"] != nil)),
        ], updatedAt: updatedAt)
    }

    private func sampleData() -> [ProviderInfo] {
        [
            ProviderInfo(id: "claude", name: "Claude", badge: "MAX 5x", provider: "claude", color: .claude, bars: [
                BarData(label: "5-hour",  value: 72),
                BarData(label: "Weekly",  value: 54),
                BarData(label: "Fable",   value: 21),
                BarData(label: "API $186.40", value: 7, window: 0),
            ], resetDate: Date().addingTimeInterval(3600), fetchedAt: Date()),
            ProviderInfo(id: "chatgpt", name: "ChatGPT", badge: "PLUS", provider: "openai", color: .openai, bars: [
                BarData(label: "5-hour", value: 33),
                BarData(label: "Weekly", value: 48),
            ], resetDate: nil, fetchedAt: Date()),
            ProviderInfo(id: "antigravity", name: "Antigravity", badge: "AI PRO", provider: "gemini", color: .geminiBlue, bars: [
                BarData(label: "Gem 3.8 · 5h", value: 0, useGradient: true),
                BarData(label: "Gem 3.8 · Wk", value: 1, useGradient: true),
                BarData(label: "C+G · 5h", value: 0),
                BarData(label: "C+G · Wk", value: 34),
            ], resetDate: Date().addingTimeInterval(7200), fetchedAt: Date()),
        ]
    }
}

// MARK: - Bar Row

struct BarRow: View {
    let bar: BarData
    let providerColor: Color
    let asOf: Date   // the timeline entry's date — countdown is computed against this

    var body: some View {
        HStack(spacing: 7) {
            Text(bar.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            UsageBar(value: max(0, bar.value),
                     color: bar.color ?? providerColor,
                     gradient: bar.useGradient,
                     height: 7,
                     pace: bar.value >= 0 ? paceFraction(reset: bar.resetDate, window: bar.window, now: asOf) : nil)

            // Table columns: % right-aligned, countdown LEFT-aligned right
            // beside it with a fixed gap — rows line up, the pair stays close.
            HStack(spacing: 5) {
                Text(bar.value < 0 ? "—" : "\(bar.value)%")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(usagePercentColor(bar.value))
                    // Wide enough for "100%" (4 chars); minimumScaleFactor is a
                    // safety net so it never truncates to "10…".
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 44, alignment: .trailing)

                Group {
                    if bar.value >= 0, let reset = bar.resetDate, reset <= asOf {
                        // Window refilled; the fresh number arrives with the next
                        // fetch (<= 5 min). Say so rather than freezing at 0:00.
                        Text("đang reset")
                    } else if bar.value >= 0, let reset = bar.resetDate, reset > asOf {
                        if reset.timeIntervalSince(asOf) < 3600 {
                            // Last hour: a system-driven timer ticks every second
                            // with NO timeline reloads (no WidgetKit budget cost).
                            Text(timerInterval: asOf...reset, countsDown: true)
                                .multilineTextAlignment(.leading)
                        } else {
                            // Hours/days: per-minute timeline entries are plenty.
                            Text(formatCountdown(reset))
                        }
                    } else {
                        Text("")
                    }
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
            }
            .lineLimit(1)
        }
    }

    private func formatCountdown(_ date: Date) -> String {
        let secs = max(0, Int(date.timeIntervalSince(asOf)))
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Provider Card (glass)

struct ProviderCard: View {
    let provider: ProviderInfo
    let asOf: Date
    // First card only: the refresh button, INSIDE the header row (an overlay
    // with hard-coded offsets collided with the card when padding changed).
    var showRefresh = false
    var clockText: String? = nil   // fetched-at time (first card, beside the refresh button)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                BrandIcon(provider: provider.provider, color: provider.color, size: 11)
                Text(provider.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                PlanBadge(tier: provider.badge, color: provider.color, fontSize: 8)
                Spacer(minLength: 6)
                // No forecast text in the widget (user: the pace tick on the
                // bars is enough; the header row has no room for name + badge +
                // forecast + clock). The app keeps the full forecast line.
                // Stale data is a warning, not commentary, so that badge stays.
                if provider.state == .ok, isStaleFetch(provider.fetchedAt, asOf: asOf) {
                    StaleBadge(fetchedAt: provider.fetchedAt, fontSize: 9.5)
                }
                if showRefresh {
                    // One capsule = fetched-at time + refresh: the time is the
                    // proof the press landed, so they belong together, and a
                    // single control leaves room for the forecast on this row.
                    Button(intent: RefreshUsageIntent()) {
                        HStack(spacing: 4) {
                            if let clockText {
                                Text(clockText).font(.system(size: 10, weight: .medium).monospacedDigit())
                            }
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, clockText == nil ? 6 : 7)
                        .frame(height: 22)
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
                VStack(spacing: 4) {
                    ForEach(provider.bars) { bar in
                        BarRow(bar: bar, providerColor: provider.color, asOf: asOf)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Flexible height: the three cards share the widget's full height, so
        // nothing is left as dead space at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 13, brand: provider.color)
    }
}

// MARK: - Widget View

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
        VStack(spacing: 6) {
            ForEach(Array(entry.providers.enumerated()), id: \.element.id) { idx, provider in
                ProviderCard(provider: provider, asOf: entry.date,
                             showRefresh: idx == 0,
                             // Clock = fetched-at of the WHOLE widget, so it sits with the
                             // refresh button, not on a provider it seems to belong to.
                             clockText: idx == 0 ? timeString : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)   // our only inset — system content margins are disabled
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

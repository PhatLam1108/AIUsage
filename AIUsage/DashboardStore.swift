// DashboardStore.swift: everything the window shows, parsed from ~/.ai_usage_cache.json,
// plus the actions (refresh, sign in, limit resets) and the "needs attention" feed.
// Views only read from here; the fetch scripts are the only writers of the cache.

import SwiftUI
import WidgetKit
import AppKit

// MARK: - Pages

enum Page: String, Hashable, CaseIterable, Identifiable {
    case overview, claude, codex, antigravity, gemini
    var id: String { rawValue }
}

// MARK: - Models

struct BarItem: Identifiable {
    let id: String
    let label: String              // "5 giờ", "Tuần", "Fable · tuần"
    let value: Int                 // % used; -1 = not reported by the service
    let color: Color?
    let gradient: Bool
    let resetDate: Date?
    let window: TimeInterval       // 0 = not a rolling window (no pace, no countdown)
    var valueText: String? = nil   // replaces the big "%" (API credit shows dollars left)
    var note: String? = nil        // replaces the countdown

    init(_ label: String, _ value: Int, color: Color? = nil, gradient: Bool = false, resetDate: Date? = nil,
         window: TimeInterval = QuotaWindow.week, valueText: String? = nil, note: String? = nil) {
        self.id = label; self.label = label; self.value = value
        self.color = color; self.gradient = gradient; self.resetDate = resetDate; self.window = window
        self.valueText = valueText; self.note = note
    }
    var reported: Bool { value >= 0 }
    var paceInput: PaceInput { PaceInput(short: label, value: value, reset: resetDate, window: window) }
}

struct ProviderData: Identifiable {
    let id: String                 // "claude" | "chatgpt" | "antigravity"
    let name: String
    let plan: String
    let logo: String               // BrandIcon key
    let color: Color
    var bars: [BarItem] = []
    var needsLogin = false
    var fetchedAt: Date? = nil
    var hasData = false            // false until the first successful fetch of this source
    var enabled = true             // switched on in the Accounts window

    /// The quota closest to its limit (what the sidebar ring shows).
    var worst: BarItem? { bars.filter { $0.reported && $0.window > 0 }.max { $0.value < $1.value } }
    var live: Bool { enabled && hasData && !needsLogin }
}

struct ClaudeAPI {
    var balance = 0.0, grant = 200.0
    var spendMonth: Double? = nil, tierLimit: Double? = nil, tierResets: Date? = nil
    var cacheHit: Int? = nil, tokens7d: Int? = nil
    var needsLogin = false
}

struct Share: Identifiable { let id = UUID(); let name: String; let pct: Int }

struct InsightSide {
    var requests = 0, sessions = 0
    var subagentHeavy = 0, longSession = 0, bigContext = 0
    var subagents: [Share] = [], models: [Share] = [], projects: [Share] = []
}

struct CodexStats {
    var sessions = 0, turns = 0, responses = 0, tokens = 0, peakContext = 0, compactions = 0
    var open = 0
    var byHost: [(host: String, turns: Int)] = []
    var lastActivity: Date? = nil
    var tokInput = 0, tokCached = 0, tokOutput = 0, tokReasoning = 0
    var models: [Share] = [], sources: [Share] = [], projects: [Share] = []
    var done = 0, failed = 0, interrupted = 0, avgTurnSec = 0
    var commands = 0, fileChanges = 0, mcpCalls = 0, webSearches = 0
}

struct RemoteStatus: Identifiable { var id: String { host }; let host: String; let ok: Bool; let at: Date? }

struct Insights {
    var day = InsightSide(), week = InsightSide()
    var hourly: [(hour: String, pct: Double)] = []
    var codexDay = CodexStats(), codexWeek = CodexStats()
    var codexAny = true
    var remote: [RemoteStatus] = []
    var present = false
}

struct CodexPeriod: Identifiable {
    let id = UUID()
    let weekly: Bool
    let start: Date, end: Date
    let pct: Double
    let models: [(String, Double)], surfaces: [(String, Double)]
}

struct CodexCredit: Identifiable {
    let id: String
    let title: String
    let granted: Date?, expires: Date?
    let status: String             // "available" | "redeemed" | …
    var available: Bool { status == "available" }
}

struct CodexResets {
    var available = 0, usableNow = 0, used30d = 0, granted30d = 0
    var lastUsed: Date? = nil
    var credits: [CodexCredit] = []
    var history: [(kind: String, at: Date)] = []
    /// The available credit that expires first: the one to spend.
    var next: CodexCredit? { credits.filter(\.available).min { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) } }
}

struct CodexHistory {
    var resets = CodexResets()
    var periods: [CodexPeriod] = []
    var daily: [(day: String, models: [String: Double])] = []
    var fetchedAt: Date? = nil
}

struct GeminiModel: Identifiable {
    let id: String; let requests: Int; let input: Int; let output: Int; let cost: Double; let priced: Bool
}

struct GeminiData {
    var balance: Double? = nil
    var topupAmount: Double? = nil, topupDate: String? = nil
    var tier: String? = nil, tierCap: Double? = nil
    var estToday = 0.0, estWeek = 0.0, estMonth = 0.0
    var exactToday: Double? = nil, exactWeek: Double? = nil, exactMonth: Double? = nil
    var exactThrough: String? = nil
    var aistudioMonth: Double? = nil
    var daily: [(day: String, cost: Double)] = []
    var models: [GeminiModel] = []
    var needsLogin = false, balanceStale = false
    var fetchedAt: Date? = nil
    var present = false

    var exact: Bool { exactMonth != nil }
    var today: Double { exact ? (exactToday ?? 0) : estToday }
    var week: Double { exact ? (exactWeek ?? 0) : estWeek }
    var month: Double { exact ? (exactMonth ?? 0) : estMonth }
    var perDay: Double { week / 7 }
    /// Days the balance lasts at the 7-day average.
    var runway: Int? { perDay > 0 ? balance.map { Int($0 / perDay) } : nil }
    var projectedMonth: Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let d = cal.component(.day, from: Date()), n = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        return d > 0 ? month / Double(d) * Double(n) : month
    }
}

// MARK: - Attention feed

struct Attention: Identifiable {
    enum Level: Int, Comparable {
        case critical, warning, info
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    enum Action { case refresh(String, String), loginClaude, loginGoogle, codexReset, claudeReset, accounts, open(Page) }
    let id: String
    let level: Level
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var action: Action? = nil
    var actionTitle: String? = nil
    var page: Page? = nil
}

// MARK: - Store

@Observable
final class DashboardStore {
    var claude = ProviderData(id: "claude", name: "Claude", plan: "MAX", logo: "claude", color: .claude)
    var chatgpt = ProviderData(id: "chatgpt", name: "ChatGPT", plan: "PLUS", logo: "openai", color: .openai)
    var agy = ProviderData(id: "antigravity", name: "Antigravity", plan: "AI PRO", logo: "gemini", color: .geminiBlue)
    var claudeAPI: ClaudeAPI? = nil
    var claudeResets = 0
    var insights = Insights()
    var codexHist = CodexHistory()
    var gemini = GeminiData()
    var config = AppConfig.load()
    var loading: Set<String> = []
    var resetMessage: String? = nil

    @ObservationIgnored private var cacheMtime: Date? = nil
    @ObservationIgnored private var timer: Timer? = nil

    var subscriptions: [ProviderData] { [claude, chatgpt, agy] }
    var anyLoading: Bool { !loading.isEmpty }

    // UI id -> fetch_one.sh argument
    static let fetchArg: [String: String] = [
        "claude": "claude", "chatgpt": "codex", "antigravity": "agy", "gemini": "gemini", "insights": "insights", "codexhist": "codexhist"
    ]

    init() {
        load()
        cacheMtime = Self.cacheModTime()
        // Background refreshes (5-min LaunchAgent, widget button) land in the cache file;
        // poll its mtime so an open window follows without a manual reload.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let m = Self.cacheModTime()
            if m != self.cacheMtime { self.cacheMtime = m; self.load() }
            let c = AppConfig.load()
            if c != self.config { self.config = c; self.load() }
        }
    }

    // MARK: Actions

    func refreshAll() {
        loading = Set(Self.fetchArg.keys)
        for (ui, arg) in Self.fetchArg { fetch(ui, arg) }
    }

    func refresh(_ ui: String) {
        guard let arg = Self.fetchArg[ui] else { return }
        loading.insert(ui)
        fetch(ui, arg)
    }

    private func fetch(_ ui: String, _ arg: String) {
        DispatchQueue.global().async {
            _ = Shell.run("/bin/bash", [AppPaths.fetchOne, arg], timeout: 240)
            DispatchQueue.main.async {
                self.load()
                self.loading.remove(ui)
                if self.loading.isEmpty { WidgetCenter.shared.reloadAllTimelines() }
            }
        }
    }

    /// Opens the helper window (sign-in, or claude.ai's usage page), then refetches once the user closes it.
    func runHelper(_ arg: String, thenFetch provider: String, spinner: String) {
        loading.insert(spinner)
        DispatchQueue.global().async {
            _ = Shell.run(AppPaths.helper, [arg], timeout: 1800)
            _ = Shell.run("/bin/bash", [AppPaths.fetchOne, provider], timeout: 240)
            DispatchQueue.main.async {
                self.load()
                self.loading.remove(spinner)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    func loginClaude() { runHelper("login", thenFetch: "claude", spinner: "claude") }
    func loginGoogle() { runHelper("login-aistudio", thenFetch: "gemini", spinner: "gemini-login") }
    func openClaudeResets() { runHelper("open", thenFetch: "claude", spinner: "claude-reset") }

    /// Asks first (a credit is spent for good), then redeems the credit that expires soonest.
    func useCodexReset() {
        let r = codexHist.resets
        guard let id = r.next?.id else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Dùng 1 lượt reset Codex?")
        alert.informativeText = String(localized: "Giới hạn tuần và 5 giờ của Codex sẽ được đặt lại ngay. Sau lần này còn \(max(0, r.available - 1)) lượt.")
        alert.addButton(withTitle: String(localized: "Dùng lượt reset"))
        alert.addButton(withTitle: String(localized: "Huỷ"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        loading.insert("codex-reset")
        Task {
            var msg: String
            do {
                let code = try await LimitReset.consumeCodex(creditID: id)
                msg = code == "already_redeemed" ? String(localized: "Lượt này đã được dùng trước đó.") : String(localized: "Đã reset giới hạn Codex.")
            } catch {
                msg = String(localized: "Reset Codex thất bại: \(error.localizedDescription)")
            }
            await MainActor.run {
                self.resetMessage = msg
                self.loading.remove("codex-reset")
                self.refresh("chatgpt")
                self.refresh("codexhist")
            }
        }
    }

    private static func cacheModTime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: AppPaths.cache))?[.modificationDate] as? Date
    }

    // MARK: Attention feed

    /// What deserves a look right now, most urgent first. Built only from data the
    /// fetch scripts already have; every entry says what to do about it.
    func attention(now: Date) -> [Attention] {
        var out: [Attention] = []
        let short = Self.dayTime

        for p in subscriptions where p.enabled {
            if !p.hasData {
                out.append(Attention(id: "nodata-\(p.id)", level: .info, icon: "person.crop.circle.badge.questionmark", tint: .secondary,
                                     title: String(localized: "\(p.name) chưa kết nối"),
                                     detail: String(localized: "Chưa có số liệu. Đăng nhập trong cửa sổ Tài khoản."),
                                     action: .accounts, actionTitle: String(localized: "Mở Tài khoản")))
                continue
            }
            if p.needsLogin {
                out.append(Attention(id: "login-\(p.id)", level: .critical, icon: "person.crop.circle.badge.exclamationmark", tint: .red,
                                     title: String(localized: "\(p.name) cần đăng nhập lại"),
                                     detail: String(localized: "Phiên đăng nhập đã hết hạn nên số liệu không cập nhật."),
                                     action: p.id == "claude" ? .loginClaude : .accounts, actionTitle: String(localized: "Đăng nhập")))
                continue
            }
            if isStaleFetch(p.fetchedAt, asOf: now) {
                out.append(Attention(id: "stale-\(p.id)", level: .warning, icon: "clock.badge.exclamationmark", tint: .orange,
                                     title: String(localized: "Số liệu \(p.name) đã cũ"),
                                     detail: String(localized: "Lần lấy thành công gần nhất: \(p.fetchedAt.map { short.string(from: $0) } ?? "chưa có")."),
                                     action: .refresh(p.id, p.name), actionTitle: String(localized: "Làm mới"), page: page(for: p.id)))
            }
            for b in p.bars where b.reported && b.window > 0 && (b.resetDate.map { $0 > now } ?? true) {
                let reset = b.resetDate.map { shortCountdown(to: $0, from: now) }
                if b.value >= 95 {
                    out.append(Attention(id: "crit-\(p.id)-\(b.id)", level: .critical, icon: "gauge.with.dots.needle.100percent", tint: .red,
                                         title: String(localized: "\(p.name) \(b.label): còn \(max(0, 100 - b.value))%"),
                                         detail: reset.map { String(localized: "Reset sau \($0).") } ?? "",
                                         page: page(for: p.id)))
                } else if let when = projectedRunOut(b.paceInput, now: now) {
                    out.append(Attention(id: "pace-\(p.id)-\(b.id)", level: .warning, icon: "chart.line.uptrend.xyaxis", tint: .orange,
                                         title: String(localized: "\(p.name) \(b.label): dự kiến hết \(runOutPhrase(when, now: now))"),
                                         detail: String(localized: "Đang dùng \(b.value)%, nhanh hơn nhịp đều.") + (reset.map { " " + String(localized: "Reset sau \($0).") } ?? ""),
                                         page: page(for: p.id)))
                }
            }
        }

        // Limit resets waiting to be spent.
        let r = codexHist.resets
        if chatgpt.enabled, r.available > 0 {
            let exp = r.next?.expires
            let soon = exp.map { $0.timeIntervalSince(now) < 3 * 86400 } ?? false
            out.append(Attention(id: "codex-reset", level: soon ? .warning : .info, icon: "arrow.counterclockwise.circle", tint: .openai,
                                 title: String(localized: "Còn \(r.available) lượt reset Codex"),
                                 detail: (exp.map { String(localized: "Lượt gần nhất hết hạn \(short.string(from: $0)).") } ?? "")
                                     + " " + (r.usableNow > 0 ? String(localized: "Dùng được ngay.") : String(localized: "Chỉ dùng được khi đang chạm giới hạn.")),
                                 action: r.usableNow > 0 ? .codexReset : nil,
                                 actionTitle: r.usableNow > 0 ? String(localized: "Dùng lượt reset") : nil, page: .codex))
        }
        if claude.enabled, claudeResets > 0 {
            out.append(Attention(id: "claude-reset", level: .info, icon: "arrow.counterclockwise.circle", tint: .claude,
                                 title: String(localized: "Còn \(claudeResets) lượt reset Claude"),
                                 detail: String(localized: "Dùng ở mục Limit resets trên trang usage của claude.ai."),
                                 action: .claudeReset, actionTitle: String(localized: "Mở trang reset"), page: .claude))
        }

        // Money.
        if config.providers.gemini, gemini.present {
            if gemini.needsLogin {
                out.append(Attention(id: "gem-login", level: .warning, icon: "person.crop.circle.badge.exclamationmark", tint: .orange,
                                     title: String(localized: "Google AI Studio cần đăng nhập lại"),
                                     detail: String(localized: "Không đọc được số dư credit."),
                                     action: .loginGoogle, actionTitle: String(localized: "Đăng nhập"), page: .gemini))
            }
            if let days = gemini.runway, days < 21 {
                out.append(Attention(id: "gem-runway", level: days < 7 ? .critical : .warning, icon: "creditcard.trianglebadge.exclamationmark",
                                     tint: days < 7 ? .red : .orange,
                                     title: String(localized: "Số dư Gemini còn đủ khoảng \(days) ngày"),
                                     detail: String(localized: "Theo mức chi trung bình 7 ngày: \(money(gemini.perDay))/ngày."), page: .gemini))
            }
            if gemini.perDay > 0, gemini.today > gemini.perDay * 2.5, gemini.today > 0 {
                out.append(Attention(id: "gem-spike", level: .warning, icon: "bolt.circle", tint: .orange,
                                     title: String(localized: "Chi Gemini hôm nay cao bất thường"),
                                     detail: String(localized: "\(money(gemini.today)), gấp \(String(format: "%.1f", gemini.today / gemini.perDay)) lần mức trung bình."), page: .gemini))
            }
        }
        if let api = claudeAPI, config.providers.console, api.grant > 0, api.balance / api.grant < 0.15 {
            out.append(Attention(id: "api-low", level: .warning, icon: "creditcard", tint: .orange,
                                 title: String(localized: "API credit Anthropic còn $\(String(format: "%.2f", api.balance))"),
                                 detail: String(localized: "Credit được cấp lại khi gia hạn gói Max."), page: .claude))
        }

        // Machines whose Claude Code numbers are missing this run.
        for h in insights.remote where !h.ok {
            out.append(Attention(id: "host-\(h.host)", level: .info, icon: "server.rack", tint: .secondary,
                                 title: String(localized: "Không kết nối được máy \(h.host)"),
                                 detail: String(localized: "Số liệu Claude Code của máy này đang là số cũ.") + (h.at.map { " " + String(localized: "Lần cuối: \(short.string(from: $0)).") } ?? ""),
                                 action: .accounts, actionTitle: String(localized: "Kiểm tra")))
        }
        return out.sorted { $0.level < $1.level }
    }

    func page(for providerID: String) -> Page {
        switch providerID {
        case "claude": return .claude
        case "chatgpt": return .codex
        default: return .antigravity
        }
    }

    static let dayTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm d/M"; f.timeZone = .current; return f
    }()

    // MARK: Cache parsing

    func load() {
        let json = (try? Data(contentsOf: URL(fileURLWithPath: AppPaths.cache)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let p = config.providers

        func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }

        // Claude
        let c = json["claude"] as? [String: Any] ?? [:]
        let weeklyReset = parseISODate(c["weekly_reset"] as? String)
        var cb = [
            BarItem(String(localized: "5 giờ"), c["session"] as? Int ?? 0, resetDate: parseISODate(c["session_reset"] as? String), window: QuotaWindow.fiveHours),
            BarItem(String(localized: "Tuần"), c["weekly"] as? Int ?? 0, resetDate: weeklyReset),
        ]
        // Per-model weekly limits (claude.ai "weekly_scoped", e.g. Fable).
        for s in c["scoped"] as? [[String: Any]] ?? [] {
            guard let label = s["label"] as? String else { continue }
            cb.append(BarItem(String(localized: "\(label) · tuần"), s["pct"] as? Int ?? 0,
                              resetDate: parseISODate(s["reset"] as? String) ?? weeklyReset))
        }
        claude = ProviderData(id: "claude", name: "Claude", plan: c["plan"] as? String ?? "MAX", logo: "claude", color: .claude,
                              bars: cb, needsLogin: c["needs_login"] as? Bool ?? false,
                              fetchedAt: parseISODate(c["fetched_at"] as? String),
                              hasData: c["session"] != nil || c["needs_login"] as? Bool == true, enabled: p.claude)
        claudeResets = (c["resets"] as? [String: Any])?["available"] as? Int ?? 0
        if let a = c["api"] as? [String: Any], let bal = num(a["balance"]), p.console {
            claudeAPI = ClaudeAPI(balance: bal, grant: max(num(a["grant"]) ?? 200, 1), spendMonth: num(a["spend_month"]),
                                  tierLimit: num(a["tier_limit"]), tierResets: parseISODate(a["tier_resets"] as? String),
                                  cacheHit: a["cache_hit"] as? Int, tokens7d: a["tokens_7d"] as? Int,
                                  needsLogin: a["needs_login"] as? Bool ?? false)
        } else {
            claudeAPI = nil
        }

        // ChatGPT / Codex
        let cx = json["codex"] as? [String: Any] ?? [:]
        chatgpt = ProviderData(id: "chatgpt", name: "ChatGPT", plan: cx["plan"] as? String ?? "PLUS", logo: "openai", color: .openai, bars: [
            BarItem(String(localized: "5 giờ"), cx["session"] as? Int ?? 0, resetDate: parseISODate(cx["session_reset"] as? String), window: QuotaWindow.fiveHours),
            BarItem(String(localized: "Tuần"), cx["weekly"] as? Int ?? 0, resetDate: parseISODate(cx["weekly_reset"] as? String)),
        ], fetchedAt: parseISODate(cx["fetched_at"] as? String), hasData: cx["session"] != nil, enabled: p.codex)

        // Antigravity
        let g = json["agy"] as? [String: Any] ?? [:]
        let ver = (g["gemini_ver"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ""
        let gem = ver.isEmpty ? "Gemini" : "Gemini \(ver)"
        agy = ProviderData(id: "antigravity", name: "Antigravity", plan: g["plan"] as? String ?? "AI PRO", logo: "gemini", color: .geminiBlue, bars: [
            BarItem(String(localized: "\(gem) · 5 giờ"), g["gemini_5h"] as? Int ?? 0, gradient: true,
                    resetDate: parseISODate(g["gemini_5h_reset"] as? String), window: QuotaWindow.fiveHours),
            BarItem(String(localized: "\(gem) · tuần"), g["gemini_weekly"] as? Int ?? 0, gradient: true,
                    resetDate: parseISODate(g["gemini_weekly_reset"] as? String)),
            BarItem(String(localized: "Claude/GPT · 5 giờ"), g["claude_gpt_5h"] as? Int ?? 0,
                    resetDate: parseISODate(g["claude_gpt_5h_reset"] as? String), window: QuotaWindow.fiveHours),
            BarItem(String(localized: "Claude/GPT · tuần"), g["claude_gpt_weekly"] as? Int ?? 0,
                    resetDate: parseISODate(g["claude_gpt_weekly_reset"] as? String)),
        ], fetchedAt: parseISODate(g["fetched_at"] as? String),
           hasData: g["gemini_weekly"] != nil || g["gemini_5h"] != nil, enabled: p.agy)

        // Codex server history + reset credits
        var ch = CodexHistory()
        if let h = json["codexhist"] as? [String: Any] {
            func pairs(_ v: Any?) -> [(String, Double)] {
                (v as? [[Any]] ?? []).compactMap { r in
                    guard r.count == 2, let k = r[0] as? String else { return nil }
                    return (k, num(r[1]) ?? 0)
                }
            }
            ch.periods = (h["periods"] as? [[String: Any]] ?? []).compactMap { q in
                guard let st = parseISODate(q["start"] as? String), let en = parseISODate(q["end"] as? String) else { return nil }
                return CodexPeriod(weekly: (q["w"] as? Int ?? 300) > 300, start: st, end: en, pct: num(q["pct"]) ?? 0,
                                   models: pairs(q["models"]), surfaces: pairs(q["surfaces"]))
            }
            ch.daily = (h["daily"] as? [[String: Any]] ?? []).compactMap { d in
                (d["d"] as? String).map { ($0, (d["models"] as? [String: Any] ?? [:]).mapValues { num($0) ?? 0 }) }
            }
            if let r = h["resets"] as? [String: Any] {
                var cr = CodexResets()
                cr.available = r["available"] as? Int ?? 0; cr.usableNow = r["usable_now"] as? Int ?? 0
                cr.used30d = r["used_30d"] as? Int ?? 0; cr.granted30d = r["granted_30d"] as? Int ?? 0
                cr.lastUsed = parseISODate(r["last_used"] as? String)
                cr.credits = (r["credits"] as? [[String: Any]] ?? []).compactMap { x in
                    guard let id = x["id"] as? String else { return nil }
                    return CodexCredit(id: id, title: x["title"] as? String ?? "Reset",
                                       granted: parseISODate(x["granted"] as? String), expires: parseISODate(x["expires"] as? String),
                                       status: x["status"] as? String ?? "available")
                }
                cr.history = (r["history"] as? [[String: Any]] ?? []).compactMap { x in
                    guard let k = x["kind"] as? String, let at = parseISODate(x["at"] as? String) else { return nil }
                    return (k, at)
                }.sorted { $0.at > $1.at }
                ch.resets = cr
            }
            ch.fetchedAt = parseISODate(h["fetched_at"] as? String)
        }
        codexHist = ch

        // Claude Code + Codex CLI insights
        var ins = Insights()
        if let i = json["insights"] as? [String: Any] {
            ins.present = true
            func shares(_ d: [String: Any], _ k: String) -> [Share] {
                (d[k] as? [[String: Any]] ?? []).compactMap { r in (r["name"] as? String).map { Share(name: $0, pct: r["pct"] as? Int ?? 0) } }
            }
            func side(_ d: [String: Any]?) -> InsightSide {
                guard let d else { return InsightSide() }
                return InsightSide(requests: d["requests"] as? Int ?? 0, sessions: d["sessions"] as? Int ?? 0,
                                   subagentHeavy: d["subagent_heavy_pct"] as? Int ?? 0, longSession: d["long_session_pct"] as? Int ?? 0,
                                   bigContext: d["big_context_pct"] as? Int ?? 0,
                                   subagents: shares(d, "subagents"), models: shares(d, "models"), projects: shares(d, "projects"))
            }
            func codex(_ d: [String: Any]?) -> CodexStats {
                guard let d else { return CodexStats() }
                var s = CodexStats()
                s.sessions = d["sessions"] as? Int ?? 0; s.turns = d["turns"] as? Int ?? 0
                s.responses = d["responses"] as? Int ?? s.turns; s.tokens = d["tokens"] as? Int ?? 0
                s.peakContext = d["peak_context_pct"] as? Int ?? 0; s.compactions = d["compactions"] as? Int ?? 0
                s.open = d["open"] as? Int ?? 0; s.avgTurnSec = d["avg_turn_s"] as? Int ?? 0
                s.byHost = (d["by_host"] as? [[String: Any]] ?? []).compactMap { h in (h["host"] as? String).map { ($0, h["turns"] as? Int ?? 0) } }
                s.lastActivity = parseISODate(d["last_activity"] as? String)
                let tok = d["tok"] as? [String: Any] ?? [:]
                s.tokInput = tok["input"] as? Int ?? 0; s.tokCached = tok["cached"] as? Int ?? 0
                s.tokOutput = tok["output"] as? Int ?? 0; s.tokReasoning = tok["reasoning"] as? Int ?? 0
                s.models = shares(d, "models"); s.sources = shares(d, "sources"); s.projects = shares(d, "projects")
                let st = d["status"] as? [String: Any] ?? [:]
                s.done = st["completed"] as? Int ?? 0; s.failed = st["failed"] as? Int ?? 0; s.interrupted = st["interrupted"] as? Int ?? 0
                let it = d["items"] as? [String: Any] ?? [:]
                s.commands = it["commandExecution"] as? Int ?? 0; s.fileChanges = it["fileChange"] as? Int ?? 0
                s.mcpCalls = it["mcpToolCall"] as? Int ?? 0; s.webSearches = it["webSearch"] as? Int ?? 0
                return s
            }
            ins.day = side(i["day"] as? [String: Any]); ins.week = side(i["week"] as? [String: Any])
            ins.hourly = (i["hourly"] as? [[String: Any]] ?? []).compactMap { h in
                (h["h"] as? String).map { (hour: $0, pct: num(h["pct"]) ?? 0) }
            }
            let cdx = i["codex"] as? [String: Any]
            ins.codexDay = codex(cdx?["day"] as? [String: Any]); ins.codexWeek = codex(cdx?["week"] as? [String: Any])
            ins.codexAny = cdx?["any"] as? Bool ?? true
            ins.remote = (i["remote"] as? [[String: Any]] ?? []).compactMap { r in
                (r["host"] as? String).map { RemoteStatus(host: $0, ok: r["ok"] as? Bool ?? false, at: parseISODate(r["at"] as? String)) }
            }
        }
        insights = ins

        // Gemini API
        var gd = GeminiData()
        if let gm = json["gemini"] as? [String: Any] {
            gd.present = true
            moneyCurrency = (gm["currency"] as? String)?.uppercased() ?? "VND"
            gd.balance = num(gm["balance"])
            if let t = gm["last_topup"] as? [String: Any] { gd.topupAmount = num(t["amount"]); gd.topupDate = t["date"] as? String }
            gd.tier = gm["tier"] as? String; gd.tierCap = num(gm["tier_cap"])
            if let e = gm["spend_est"] as? [String: Any] { gd.estToday = num(e["today"]) ?? 0; gd.estWeek = num(e["week"]) ?? 0; gd.estMonth = num(e["month"]) ?? 0 }
            if let e = gm["spend_exact"] as? [String: Any] { gd.exactToday = num(e["today"]); gd.exactWeek = num(e["week"]); gd.exactMonth = num(e["month"]) }
            gd.exactThrough = gm["exact_through"] as? String
            gd.aistudioMonth = num(gm["spend_aistudio_month"])
            gd.daily = (gm["daily"] as? [[String: Any]] ?? []).compactMap { r in (r["d"] as? String).map { ($0, num(r["cost"]) ?? 0) } }
            gd.models = (gm["models"] as? [[String: Any]] ?? []).compactMap { r in
                guard let m = r["model"] as? String else { return nil }
                return GeminiModel(id: m, requests: r["requests"] as? Int ?? 0, input: r["in"] as? Int ?? 0, output: r["out"] as? Int ?? 0,
                                   cost: num(r["cost"]) ?? 0, priced: r["priced"] as? Bool ?? false)
            }
            gd.needsLogin = gm["needs_login_google"] as? Bool ?? false
            gd.balanceStale = gm["balance_stale"] as? Bool ?? false
            gd.fetchedAt = parseISODate(gm["fetched_at"] as? String)
        }
        gemini = gd
    }
}

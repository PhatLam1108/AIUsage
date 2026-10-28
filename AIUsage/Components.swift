// Components.swift: the app's building blocks (panels, quota tiles, ring gauges,
// share rows, heat grids) and number/date formatting. Pages compose these only.
//
// Shape rule: panels 14pt, tiles and grid cells 8 to 10pt, controls native.
// Colour rule: provider colour identifies the service; severity (orange/red)
// is only ever applied to numbers and status text, never to whole surfaces.

import SwiftUI

extension Color {
    static let hairline = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08))
    static let tileBG = Color(light: Color.black.opacity(0.035), dark: Color.white.opacity(0.045))
}

// MARK: - Formatting

/// ISO code of the Gemini billing currency, set from the cache on every load.
var moneyCurrency = "VND"

/// An amount in the Gemini billing currency: "₫412.000" for VND, the system currency style otherwise.
func money(_ v: Double) -> String {
    let f = NumberFormatter()
    if moneyCurrency == "VND" {
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        f.groupingSize = 3
        f.maximumFractionDigits = 0
        return "₫" + (f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))")
    }
    // Other currencies in the international style ("$84.20", "€12.50"), matching the
    // USD amounts Anthropic shows, whatever the system region is.
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .currency
    f.currencyCode = moneyCurrency
    f.maximumFractionDigits = v >= 1000 ? 0 : 2
    return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
}

func usd(_ v: Double) -> String { "$" + String(format: "%.2f", v) }

func tokens(_ v: Int) -> String {
    if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1e6) }
    if v >= 1_000 { return String(format: "%.0fk", Double(v) / 1e3) }
    return "\(v)"
}

/// yyyy-mm-dd of `d` in local time (the fetch script's day keys).
func localDay(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f.string(from: d)
}

/// "2026-09-16" -> "16/9"
func dayLabel(_ ymd: String?) -> String {
    let p = (ymd ?? "").split(separator: "-"); guard p.count == 3, let d = Int(p[2]), let m = Int(p[1]) else { return "?" }
    return "\(d)/\(m)"
}

func durationLabel(_ s: Int) -> String {
    s >= 3600 ? String(format: "%.1fh", Double(s) / 3600) : s >= 60 ? "\(s / 60)m" : "\(s)s"
}

func shortModel(_ m: String) -> String { m.hasPrefix("gpt-") ? String(m.dropFirst(4)) : m }

func surfaceName(_ s: String) -> String {
    ["work_desktop": "Codex app", "desktop_app": "ChatGPT app", "cli": "CLI", "exec": "codex exec", "vscode": "VS Code", "unknown": String(localized: "khác")][s] ?? s
}

/// "14:00 hôm nay", "07:00 T5 29/10": when a window refills, in plain local time.
func resetClock(_ d: Date, now: Date) -> String {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let f = DateFormatter(); f.timeZone = .current
    if cal.isDate(d, inSameDayAs: now) { f.dateFormat = "HH:mm"; return f.string(from: d) + " " + String(localized: "hôm nay") }
    let wd = cal.component(.weekday, from: d)
    f.dateFormat = "HH:mm d/M"
    return f.string(from: d).replacingOccurrences(of: " ", with: " " + (wd == 1 ? "CN" : "T\(wd)") + " ")
}

// MARK: - Pace reading

/// How a quota is tracking against an even spread across its window.
struct QuotaRead {
    var expected: Int? = nil      // % an even pace would have used by now
    var delta: Int? = nil         // used minus expected (positive = burning faster)
    var safeRate: String? = nil   // the rate that lands exactly on 100% at the reset
}

func quotaRead(_ b: BarItem, now: Date) -> QuotaRead {
    guard b.reported, b.window > 0, let reset = b.resetDate, reset > now,
          let frac = paceFraction(reset: reset, window: b.window, now: now) else { return QuotaRead() }
    let expected = Int((frac * 100).rounded())
    let hours = reset.timeIntervalSince(now) / 3600
    let left = Double(max(0, 100 - b.value))
    var safe: String? = nil
    if hours > 0, b.value < 100 {
        // Per day only while at least a day is left; otherwise per hour.
        safe = hours >= 24
            ? String(localized: "\(String(format: "%.0f", left / (hours / 24)))%/ngày")
            : String(localized: "\(String(format: left / hours >= 10 ? "%.0f" : "%.1f", left / hours))%/giờ")
    }
    return QuotaRead(expected: expected, delta: b.value - expected, safeRate: safe)
}

// MARK: - Panel

/// The one container: titled card with a quiet trailing note.
struct Panel<Content: View, Accessory: View>: View {
    var title: LocalizedStringKey? = nil
    var icon: String? = nil
    var note: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || note != nil {
                HStack(spacing: 6) {
                    if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                    if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
                    Spacer(minLength: 8)
                    if let note { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                    accessory()
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.cardBG))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: LocalizedStringKey? = nil, icon: String? = nil, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.note = note
        self.accessory = { EmptyView() }; self.content = content
    }
}

/// Section heading between groups of panels on a page.
struct SectionHeading<Accessory: View>: View {
    let title: LocalizedStringKey
    var detail: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: LocalizedStringKey, detail: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title; self.detail = detail; self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            accessory()
        }
        .padding(.top, 6)
    }
}

extension SectionHeading where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, detail: String? = nil) { self.title = title; self.detail = detail; self.accessory = { EmptyView() } }
}

// MARK: - Ring gauge

/// Circular quota meter: fill = % used, tick = where an even pace would be.
struct RingGauge: View {
    let value: Int                 // -1 = not reported
    let color: Color
    var gradient = false
    var pace: Double? = nil
    var size: CGFloat = 68
    var line: CGFloat = 7
    var showText = true

    var body: some View {
        let v = CGFloat(max(0, min(100, value))) / 100
        ZStack {
            Circle().stroke(Color.barTrack, lineWidth: line)
            if value > 0 {
                Circle()
                    .trim(from: 0, to: v)
                    .stroke(gradient ? AnyShapeStyle(AngularGradient(colors: [.geminiBlue, .geminiPurple, .geminiPink, .geminiBlue], center: .center))
                                     : AnyShapeStyle(color),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let pace, value >= 0 {
                Capsule()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 2, height: line + 4)
                    .offset(y: -(size - line) / 2)
                    .rotationEffect(.degrees(360 * pace))
            }
            if showText {
                Text(value < 0 ? "–" : "\(value)%")
                    .font(.system(size: size * 0.24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(usagePercentColor(value))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(line + 2)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Quota tile

/// One quota: big % used, bar with the even-pace tick, countdown, and two plain
/// readings: whether usage runs ahead of an even pace, and the rate that still lasts.
struct QuotaTile: View {
    let bar: BarItem
    let color: Color
    let now: Date
    var footer: [String]? = nil    // replaces the pace readings (API credit)

    var body: some View {
        let read = quotaRead(bar, now: now)
        let pace = bar.reported ? paceFraction(reset: bar.resetDate, window: bar.window, now: now) : nil
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(bar.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(cornerText).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            }
            Text(bar.valueText ?? (bar.reported ? "\(bar.value)%" : "–"))
                .font(.system(size: 25, weight: .semibold).monospacedDigit())
                .foregroundStyle(bar.valueText == nil ? usagePercentColor(bar.value) : .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            UsageBar(value: max(0, bar.value), color: bar.color ?? color, gradient: bar.gradient, height: 5, pace: pace)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) { lines(read) }
                .font(.system(size: 10.5))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.tileBG))
        .help(helpText(read))
    }

    private var cornerText: String {
        if let note = bar.note { return note }
        guard bar.reported, let r = bar.resetDate else { return "" }
        return r <= now ? String(localized: "đang reset") : shortCountdown(to: r, from: now)
    }

    @ViewBuilder private func lines(_ read: QuotaRead) -> some View {
        if let footer {
            ForEach(footer, id: \.self) { Text($0).foregroundStyle(.secondary) }
        } else if !bar.reported {
            Text("Dịch vụ chưa báo số này").foregroundStyle(.tertiary)
            Text(" ")
        } else if let r = bar.resetDate, r <= now {
            Text("Đã tới giờ reset").foregroundStyle(.secondary)
            Text("Số mới có ở lần làm mới tới").foregroundStyle(.tertiary)
        } else if let d = read.delta {
            HStack(spacing: 4) {
                Image(systemName: d > 5 ? "hare.fill" : d < -5 ? "tortoise.fill" : "equal.circle.fill")
                Text(d > 5 ? String(localized: "Nhanh hơn nhịp \(d) điểm")
                     : d < -5 ? String(localized: "Chậm hơn nhịp \(-d) điểm") : String(localized: "Đúng nhịp đều"))
            }
            .foregroundStyle(d > 5 ? Color.orange : Color.secondary)
            Text(read.safeRate.map { String(localized: "Còn dùng được \($0)") } ?? " ").foregroundStyle(.tertiary)
        } else {
            Text(" ")
            Text(" ")
        }
    }

    private func helpText(_ read: QuotaRead) -> String {
        guard bar.reported, let reset = bar.resetDate else { return bar.label }
        var t = String(localized: "\(bar.label): đã dùng \(bar.value)%, reset lúc \(resetClock(reset, now: now)).")
        if let e = read.expected { t += "\n" + String(localized: "Nếu dùng đều, lúc này mới tới \(e)%.") }
        if let s = read.safeRate { t += "\n" + String(localized: "Giữ dưới \(s) để không chạm trần trước giờ reset.") }
        return t
    }
}

// MARK: - Small pieces

struct Metric: View {
    let value: String
    let label: String
    var tint: Color = .primary
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: size, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShareRow: View {
    let name: String
    let pct: Int
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 120, maxWidth: 220, alignment: .leading)
                UsageBar(value: pct, color: color, height: 5)
                Text("\(pct)%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
        }
    }
}

struct EmptyNote: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A source the user switched off or has not connected: one line plus the way into Accounts.
struct NotConnected: View {
    let text: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsLink { Label("Mở Tài khoản", systemImage: "person.crop.circle.badge.plus") }
                .buttonStyle(.glass)
        }
    }
}

struct ProviderMark: View {
    let logo: String
    let color: Color
    var size: CGFloat = 13
    var body: some View {
        if logo == "geminiAPI" { GeminiMark(size: size * 1.78) } else { BrandIcon(provider: logo, color: color, size: size) }
    }
}

/// Plan badge plus the stale warning, used in every page and card header.
struct ProviderStatus: View {
    let p: ProviderData
    let now: Date
    var body: some View {
        HStack(spacing: 6) {
            PlanBadge(tier: p.plan, color: p.color, fontSize: 8.5)
            if p.live, isStaleFetch(p.fetchedAt, asOf: now) { StaleBadge(fetchedAt: p.fetchedAt, fontSize: 10) }
        }
    }
}

// MARK: - Heat grid

struct HeatCell {
    let label: String
    let value: Double
    let valueText: String?
    let help: String
    var isNow = false
}

/// Rows of equal cells whose colour depth tracks the value (sqrt scale so small values still show).
struct HeatGrid: View {
    let rows: [(String, [HeatCell?])]
    let header: [String]?
    let color: Color
    var rowHeight: CGFloat? = nil      // nil = rows share whatever height the grid gets
    var labelWidth: CGFloat = 44

    var body: some View {
        let top = max(rows.flatMap { $0.1 }.compactMap { $0?.value }.max() ?? 0, 0.0001)
        let labelled = rows.contains { !$0.0.isEmpty }
        VStack(spacing: 4) {
            if let header {
                HStack(spacing: 4) {
                    if labelled { Color.clear.frame(width: labelWidth, height: 1) }
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        Text(h).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    if labelled {
                        Text(row.0).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                            .frame(width: labelWidth, alignment: .leading).lineLimit(1)
                    }
                    ForEach(Array(row.1.enumerated()), id: \.offset) { _, c in cell(c, top: top) }
                }
                .frame(minHeight: rowHeight ?? 22, maxHeight: rowHeight ?? .infinity)
            }
            HStack(spacing: 3) {
                Spacer()
                Text("ít").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { t in
                    RoundedRectangle(cornerRadius: 2.5).fill(fill(t)).frame(width: 11, height: 8)
                }
                Text("nhiều").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
    }

    private func fill(_ t: Double) -> Color { t > 0 ? color.opacity(0.14 + 0.76 * t) : Color.tileBG }

    @ViewBuilder private func cell(_ c: HeatCell?, top: Double) -> some View {
        if let c {
            let t = c.value > 0 ? sqrt(c.value / top) : 0
            let strong = t > 0.6
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill(t))
                if c.isNow {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.65), lineWidth: 1.2)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.label).font(.system(size: 9.5)).foregroundStyle(strong ? Color.white.opacity(0.8) : Color.secondary)
                    Spacer(minLength: 0)
                    if let v = c.valueText {
                        Text(v).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(strong ? Color.white : Color.primary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .help(c.help)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Stacked bar of parts with a legend (Codex token mix).
struct StackedBar: View {
    let parts: [(name: String, n: Int, color: Color)]

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.n })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        if p.n > 0 {
                            Rectangle().fill(p.color).frame(width: max(2, (geo.size.width - 6) * CGFloat(p.n) / CGFloat(total)))
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 14) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(p.color).frame(width: 8, height: 8)
                        Text("\(p.name) \(Int((100.0 * Double(p.n) / Double(total)).rounded()))%")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .help("\(p.name): \(tokens(p.n)) token")
                }
            }
        }
    }
}

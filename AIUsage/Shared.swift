// Shared.swift — compiled into BOTH the app target and the widget extension.
// Single source of truth for: brand colors (adaptive light/dark), brand SVG
// logos, the SVG path parser, and the ISO-8601 date helper.

import SwiftUI
import AppKit

// MARK: - Adaptive colors (follow the system light/dark appearance)

extension Color {
    /// A color that resolves differently under light vs dark system appearance.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    // Brand palette — deeper in light mode (contrast on white), more vivid in
    // dark mode (pop on black).
    static let claude = Color(light: Color(red: 0.851, green: 0.467, blue: 0.341),
                              dark:  Color(red: 0.940, green: 0.490, blue: 0.320))
    static let openai = Color(light: Color(red: 0.063, green: 0.639, blue: 0.498),
                              dark:  Color(red: 0.100, green: 0.740, blue: 0.580))
    static let geminiBlue = Color(light: Color(red: 0.259, green: 0.522, blue: 0.957),
                                  dark:  Color(red: 0.400, green: 0.620, blue: 1.000))
    static let geminiPurple = Color(light: Color(red: 0.569, green: 0.408, blue: 0.753),
                                    dark:  Color(red: 0.660, green: 0.510, blue: 0.860))
    static let geminiPink = Color(light: Color(red: 0.851, green: 0.396, blue: 0.439),
                                  dark:  Color(red: 0.960, green: 0.480, blue: 0.550))

    // Neutral bar track — brand-tinted tracks turned muddy on the dark glass.
    static let barTrack    = Color(light: Color.black.opacity(0.09), dark: Color.white.opacity(0.10))

    // Solid surfaces: translucent glass turned to grey mud over bright desktop
    // content, so the app/widget use opaque deep surfaces — colours stay true
    // regardless of what's behind the window.
    static let appBGTop = Color(light: Color(red: 0.972, green: 0.972, blue: 0.982),
                                dark:  Color(red: 0.102, green: 0.102, blue: 0.118))
    static let appBG    = Color(light: Color(red: 0.936, green: 0.936, blue: 0.952),
                                dark:  Color(red: 0.058, green: 0.058, blue: 0.068))
    static let cardBG   = Color(light: Color.white,
                                dark:  Color(red: 0.128, green: 0.131, blue: 0.150))
    // "Edge light": hairline stroke brighter on top, fading toward the bottom —
    // reads as light catching the card's upper edge.
    static let edgeTop    = Color(light: Color.black.opacity(0.10), dark: Color.white.opacity(0.17))
    static let edgeBottom = Color(light: Color.black.opacity(0.03), dark: Color.white.opacity(0.03))
}

// MARK: - Card surface (shared by app + widget)

/// Opaque card: solid fill, a faint brand wash at the top, hairline edge, soft shadow.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat
    var brand: Color

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.cardBG)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [brand.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.edgeTop, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        )
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat, brand: Color) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, brand: brand))
    }
}

// Usage severity at a glance: calm until 65 %, orange when worth noticing,
// red when the window is nearly burned through.
func usagePercentColor(_ value: Int) -> Color {
    if value < 0 { return .secondary }
    if value >= 85 { return .red }
    if value >= 65 { return .orange }
    return .primary
}

// MARK: - Shared UI components (app + widget)

/// Glossy brand icon chip with a per-brand gradient.
struct BrandIcon: View {
    let provider: String
    let color: Color
    let size: CGFloat   // reference size; the chip itself is ~1.78×

    // The providers' own app icons (from the installed Claude / ChatGPT /
    // Antigravity apps), not redrawn marks — the SVG glyphs we used before
    // were the Anthropic company mark and the Gemini sparkle, i.e. the wrong
    // logos for the Claude and Antigravity products.
    private var assetName: String {
        switch provider {
        case "claude": return "LogoClaude"
        case "openai": return "LogoChatGPT"
        default:       return "LogoAntigravity"
        }
    }

    var body: some View {
        let chip = size * 1.78
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: chip, height: chip)
            .clipShape(RoundedRectangle(cornerRadius: chip * 0.24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: chip * 0.24, style: .continuous)
                    .strokeBorder(Color.edgeTop, lineWidth: 0.5)
            )
            .shadow(color: color.opacity(0.35), radius: 3, x: 0, y: 1.5)
    }
}

/// Plan tier capsule (MAX 20X / PLUS / AI PRO).
struct PlanBadge: View {
    let tier: String
    let color: Color
    var fontSize: CGFloat = 8

    var body: some View {
        Text(tier.uppercased())
            .font(.system(size: fontSize, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: fontSize * 1.9)
            .background(Capsule().fill(color.opacity(0.20)))
            .overlay(Capsule().strokeBorder(color.opacity(0.38), lineWidth: 0.5))
    }
}

/// Capsule usage bar: neutral track, flat fill (Gemini models get the brand gradient).
struct UsageBar: View {
    let value: Int
    let color: Color
    var gradient = false
    var height: CGFloat = 6
    /// Fraction (0...1) of the window already elapsed. Drawn as a small tick:
    /// "where you'd be if you spread usage evenly". Fill past it = ahead of pace.
    var pace: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let r = h / 2
            // Clean neutral track — brand-tinted tracks read as dirty/muddy on glass.
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r)
            ctx.fill(track, with: .color(Color.barTrack))

            guard value > 0 else { return }
            let fillW = max(h, size.width * CGFloat(min(100, value)) / 100)
            let fillPath = Path(roundedRect: CGRect(x: 0, y: 0, width: fillW, height: h), cornerRadius: r)
            if gradient {
                ctx.fill(fillPath, with: .linearGradient(
                    Gradient(colors: [.geminiBlue, .geminiPurple, .geminiPink]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            } else {
                ctx.fill(fillPath, with: .color(color))
            }
        }
        .frame(height: height)
        .overlay {
            if let pace {
                GeometryReader { geo in
                    let x = min(max(geo.size.width * pace, 1.5), geo.size.width - 1.5)
                    // Card-coloured halo keeps the tick legible over both the
                    // saturated fill and the pale track.
                    Capsule().fill(Color.cardBG)
                        .frame(width: 4.5, height: height + 7)
                        .position(x: x, y: geo.size.height / 2)
                    Capsule().fill(Color.primary.opacity(0.78))
                        .frame(width: 2, height: height + 5)
                        .position(x: x, y: geo.size.height / 2)
                }
            }
        }
    }
}

// MARK: - ISO-8601 helper

func parseISODate(_ str: String?) -> Date? {
    guard let str = str, !str.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: str) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: str)
}

// MARK: - Per-provider staleness (shared by app + widget)

/// A provider is stale when its own last SUCCESSFUL fetch is older than 90 min
/// (3 LaunchAgent cycles). Checked per card on purpose: a single global clock
/// let a broken Claude parser hide behind Codex/agy's successful fetches for
/// two days (2026-09-24 → 26). Missing timestamp = never fetched = stale.
func isStaleFetch(_ fetchedAt: Date?, asOf now: Date) -> Bool {
    guard let fetchedAt else { return true }
    return now.timeIntervalSince(fetchedAt) > 5400
}

/// Orange warning shown in a card header when that provider's numbers are old:
/// triangle + the time of its last good fetch (local time).
struct StaleBadge: View {
    let fetchedAt: Date?
    var fontSize: CGFloat = 10

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone.current
        return f
    }()

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: fontSize - 1.5))
            Text(fetchedAt.map { Self.formatter.string(from: $0) } ?? "—")
                .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.orange)
        .help("Dữ liệu cũ: lần lấy số thành công gần nhất của nguồn này")
    }
}


// MARK: - Pace forecast (shared by app + widget)

enum QuotaWindow {
    static let fiveHours: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400
}

/// One quota bar as the pace logic sees it.
struct PaceInput {
    let short: String          // how the status line names it ("Tuần", "Gem 5h")
    let value: Int             // % used, -1 = n/a
    let reset: Date?
    let window: TimeInterval
}

/// Fraction of the window already elapsed at `now`, or nil if unknown.
func paceFraction(reset: Date?, window: TimeInterval, now: Date) -> Double? {
    guard let reset, reset > now else { return nil }
    let remaining = reset.timeIntervalSince(now)
    guard remaining <= window * 1.05 else { return nil }   // bogus reset time
    return min(1, max(0, 1 - remaining / window))
}

/// When this quota hits 100% if usage keeps its current average rate — nil if
/// it lasts until the reset, or it's too early in the window to judge.
func projectedRunOut(_ b: PaceInput, now: Date) -> Date? {
    guard b.value > 0, b.value < 100, let reset = b.reset, reset > now else { return nil }
    let remaining = reset.timeIntervalSince(now)
    let elapsed = b.window - remaining
    guard elapsed > b.window * 0.10 else { return nil }    // first 10%: too noisy
    let toFull = Double(100 - b.value) / (Double(b.value) / elapsed)
    return toFull < remaining ? now.addingTimeInterval(toFull) : nil
}

enum PaceLevel { case critical, fast, ok }

struct PaceStatus {
    let level: PaceLevel
    let text: String       // full sentence (app, which has room for a line)
    let compact: String    // header-sized version (widget, no spare line)
}

/// The one line a card shows under its bars: the most urgent thing about it.
func paceStatus(_ bars: [PaceInput], now: Date) -> PaceStatus? {
    // A bar whose reset time has already passed holds pre-reset numbers until
    // the next fetch — don't warn "0% left, resets in 0m" about a window that
    // has in fact just refilled.
    let live = bars.filter { b in b.value >= 0 && (b.reset.map { $0 > now } ?? true) }
    guard !live.isEmpty else { return nil }

    if let worst = live.filter({ $0.value >= 95 }).max(by: { $0.value < $1.value }) {
        let left = max(0, 100 - worst.value)
        let text = worst.reset.map { String(localized: "\(worst.short): còn \(left)%, reset sau \(shortCountdown(to: $0, from: now))") }
            ?? String(localized: "\(worst.short): còn \(left)%")
        return PaceStatus(level: .critical, text: text,
                          compact: String(localized: "\(worst.short) còn \(left)%"))
    }
    let runOuts = live.compactMap { b in projectedRunOut(b, now: now).map { (b, $0) } }
    if let (b, when) = runOuts.min(by: { $0.1 < $1.1 }) {
        let phrase = runOutPhrase(when, now: now)
        return PaceStatus(level: .fast,
                          text: String(localized: "\(b.short): dự kiến hết \(phrase)"),
                          compact: String(localized: "\(b.short) hết \(phrase)"))
    }
    return PaceStatus(level: .ok, text: String(localized: "Dư dả, dùng chậm hơn nhịp"), compact: String(localized: "Dư dả"))
}

func shortCountdown(to date: Date, from now: Date) -> String {
    let secs = max(0, Int(date.timeIntervalSince(now)))
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// "lúc 21:40" today, "chiều mai", "sáng thứ 3", "tối CN" (local time; English: "at 21:40",
/// "tomorrow afternoon", "Tuesday morning").
func runOutPhrase(_ date: Date, now: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    if cal.isDate(date, inSameDayAs: now) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = cal.timeZone
        return String(localized: "lúc \(f.string(from: date))")
    }
    let hour = cal.component(.hour, from: date)
    let part = hour < 12 ? 0 : (hour < 18 ? 1 : 2)
    if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
        return [String(localized: "sáng mai"), String(localized: "chiều mai"), String(localized: "tối mai")][part]
    }
    let wd = cal.component(.weekday, from: date)   // 1 = Sunday
    let day = [String(localized: "CN"), String(localized: "thứ 2"), String(localized: "thứ 3"), String(localized: "thứ 4"),
               String(localized: "thứ 5"), String(localized: "thứ 6"), String(localized: "thứ 7")][wd - 1]
    return [String(localized: "sáng \(day)"), String(localized: "chiều \(day)"), String(localized: "tối \(day)")][part]
}

/// Icon + text line under a card's bars, coloured by urgency.
struct PaceStatusLine: View {
    let status: PaceStatus
    var fontSize: CGFloat = 10.5
    var compact = false

    private var icon: String {
        switch status.level {
        case .critical: return "exclamationmark.triangle.fill"
        case .fast:     return "chart.line.uptrend.xyaxis"
        case .ok:       return "checkmark.circle.fill"
        }
    }
    private var tint: Color {
        switch status.level {
        case .critical: return .red
        case .fast:     return .orange
        case .ok:       return .green
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: fontSize - 0.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(compact ? status.compact : status.text)
                .font(.system(size: fontSize, weight: .medium))
                // Calm state stays quiet; only warnings take the colour.
                .foregroundStyle(status.level == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}

// CastController.swift: shows the dashboard on a Cast display (Nest Hub).
//
// Finds Cast devices on the LAN (Bonjour _googlecast._tcp), launches the AIUsage receiver page
// on the one the user picked, and pushes a compact JSON snapshot whenever the numbers change
// (at least every few minutes, so the screen can tell a sleeping Mac from quiet numbers).
// The receiver does all the drawing and the per-second countdowns itself.
//
// The controller owns its own DashboardStore, so casting goes on with the window closed.
// Stopping the AIUsage app on the device (voice, touch, or casting something else) turns
// casting off here too: the Mac never fights the person in front of the screen.

import Foundation
import Network
import Observation

struct CastDevice: Identifiable, Equatable {
    let id: String          // TXT "id": stable across IP changes
    let name: String        // TXT "fn": the room name set in Google Home
    let model: String       // TXT "md"
    let endpoint: NWEndpoint

    static func == (a: CastDevice, b: CastDevice) -> Bool { a.id == b.id && a.name == b.name && a.model == b.model }
}

@Observable
final class CastController {
    static let shared = CastController()

    /// Custom receiver registered in the Google Cast SDK Developer Console; its URL is
    /// the page in cast-receiver/. `defaults write com.stevenlam.AIUsage castAppID <id>` overrides it.
    static let registeredAppID = "46040F28"

    enum Status: Equatable { case off, searching, connecting, launching, showing, failed(String) }

    private(set) var devices: [CastDevice] = []
    private(set) var status: Status = .off
    /// The display chosen last (kept when casting stops, so one click starts it again).
    private(set) var deviceID: String? = UserDefaults.standard.string(forKey: "castDeviceID")
    private(set) var enabled = UserDefaults.standard.bool(forKey: "castEnabled")

    var appID: String {
        let o = UserDefaults.standard.string(forKey: "castAppID") ?? ""
        return o.isEmpty ? Self.registeredAppID : o
    }
    var configured: Bool { !appID.isEmpty }
    var device: CastDevice? { devices.first { $0.id == deviceID } }
    var showing: Bool { status == .showing }

    @ObservationIgnored private lazy var store = DashboardStore()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: CastChannel?
    @ObservationIgnored private var transportID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var launchSent = false
    /// Set only by the user picking a display; resume and reconnects only join a running session,
    /// so a display someone stopped is never reopened behind their back.
    @ObservationIgnored private var launchAllowed = false
    @ObservationIgnored private var joined = false
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var lastInbound = Date()
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var pusher: Timer?
    @ObservationIgnored private var retry: Timer?
    @ObservationIgnored private var launchDeadline: Date?
    @ObservationIgnored private var retryDelay: TimeInterval = 5
    @ObservationIgnored private var lastBody: String?
    @ObservationIgnored private var lastPush = Date.distantPast
    /// Bumped on every disconnect; events tagged with an older value are ignored.
    @ObservationIgnored private var generation = 0

    static let sender = "sender-0"
    static let platform = "receiver-0"
    /// CONNECT with the sender description the official SDKs send. A bare CONNECT got its
    /// LAUNCH cancelled on a Nest Hub (2026-11-12); with this one the launch went through.
    static let connect: [String: Any] = [
        "type": "CONNECT", "origin": [String: Any](), "userAgent": "AIUsage",
        "senderInfo": ["sdkType": 2, "version": "15.605.1.3", "browserVersion": "44.0.2403.30",
                       "platform": 4, "systemVersion": "Macintosh", "connectionType": 1],
    ]

    /// Called at app launch: picks casting up again if it was on when the app quit. Only joins
    /// an AIUsage session still running on the display; it never opens one by itself.
    func resume() {
        guard enabled, configured, deviceID != nil else { return }
        launchAllowed = false
        status = .searching
        startBrowsing()
    }

    /// Show the dashboard on `device` (switches over if another display was in use, or picks
    /// it up again right after a stop whose teardown is still pending).
    func cast(to device: CastDevice) {
        guard configured else { status = .failed(String(localized: "Chưa có App ID của receiver")); return }
        deviceID = device.id
        enabled = true
        launchAllowed = true
        save()
        retryDelay = 5
        connect(device)
    }

    /// Stop showing: closes the AIUsage app on the display and stays off until picked again.
    func stop() {
        enabled = false
        launchAllowed = false
        save()
        if let channel, let sessionID {
            requestID += 1
            channel.send(from: Self.sender, to: Self.platform, namespace: CastNamespace.receiver,
                         ["type": "STOP", "sessionId": sessionID, "requestId": requestID])
        }
        // Let the STOP leave before the socket closes; a new cast(to:) in between has its own generation.
        let stopping = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.generation == stopping else { return }
            self.disconnect()
        }
        status = .off
    }

    // MARK: Discovery

    /// Ends discovery unless casting needs it (the popover calls this when it closes).
    func stopBrowsingIfIdle() {
        guard !enabled else { return }
        browser?.cancel()
        browser = nil
    }

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.device(from:))
            DispatchQueue.main.async { self?.updateDevices(found) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.async {
                    self?.browser = nil
                    if self?.enabled == true { self?.status = .failed(String(localized: "Không dò được mạng nội bộ")) }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private static func device(from result: NWBrowser.Result) -> CastDevice? {
        guard case let .bonjour(txt) = result.metadata, let id = txt["id"] else { return nil }
        // "ca" is a capability bitmask; bit 0 = video out. Speakers can't show a dashboard.
        if let ca = txt["ca"].flatMap(Int.init), ca & 1 == 0 { return nil }
        var fallback = ""
        if case let .service(name, _, _, _) = result.endpoint { fallback = name }
        return CastDevice(id: id, name: txt["fn"] ?? fallback, model: txt["md"] ?? "", endpoint: result.endpoint)
    }

    private func updateDevices(_ found: [CastDevice]) {
        // One entry per device (it is advertised on every interface).
        var seen = Set<String>()
        devices = found.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if enabled, channel == nil, retry == nil, let d = device { connect(d) }
    }

    // MARK: Connection

    private func connect(_ device: CastDevice) {
        disconnect()
        status = .connecting
        let serial = generation
        let ch = CastChannel(endpoint: device.endpoint) { [weak self] event in
            // Events of a connection already dropped can still be queued; acting on them
            // after a stop showed "opening AIUsage…" while casting was off (2026-11-12).
            guard let self, self.generation == serial else { return }
            self.handle(event)
        }
        channel = ch
        ch.start()
    }

    private func disconnect() {
        generation += 1
        heartbeat?.invalidate(); heartbeat = nil
        pusher?.invalidate(); pusher = nil
        retry?.invalidate(); retry = nil
        let ch = channel
        channel = nil
        ch?.cancel()
        transportID = nil; sessionID = nil
        launchSent = false; joined = false
        launchDeadline = nil
        lastBody = nil
    }

    private func handle(_ event: CastChannel.Event) {
        switch event {
        case .ready:
            lastInbound = Date()
            send(to: Self.platform, CastNamespace.connection, Self.connect)
            requestID += 1
            send(to: Self.platform, CastNamespace.receiver, ["type": "GET_STATUS", "requestId": requestID])
            heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.beat() }
        case .message(let m):
            lastInbound = Date()
            receive(m)
        case .closed(let reason):
            disconnect()
            guard enabled else { status = .off; return }
            scheduleRetry(reason)
        }
    }

    private func scheduleRetry(_ reason: String?) {
        status = .failed(reason.map { String(localized: "Mất kết nối (\($0)), đang thử lại") } ?? String(localized: "Mất kết nối, đang thử lại"))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retry = nil
            guard self.enabled else { return }
            if let d = self.device { self.connect(d) } else { self.status = .searching; self.startBrowsing() }
        }
    }

    private func beat() {
        guard let channel else { return }
        if Date().timeIntervalSince(lastInbound) > 20 {
            channel.cancel()        // device stopped answering; .closed brings the retry
            return
        }
        if let deadline = launchDeadline, Date() > deadline {
            launchDeadline = nil
            enabled = false; save()
            disconnect()
            status = .failed(String(localized: "Thiết bị không mở được AIUsage"))
            return
        }
        send(to: Self.platform, CastNamespace.heartbeat, ["type": "PING"])
    }

    private func receive(_ m: CastMessage) {
        guard let json = m.json, let type = json["type"] as? String else { return }
        switch (m.namespace, type) {
        case (CastNamespace.heartbeat, "PING"):
            send(to: m.source, CastNamespace.heartbeat, ["type": "PONG"])
        case (CastNamespace.receiver, "RECEIVER_STATUS"):
            let status = json["status"] as? [String: Any]
            receiverStatus(status?["applications"] as? [[String: Any]] ?? [])
        case (CastNamespace.receiver, "LAUNCH_ERROR"):
            let reason = json["reason"] as? String ?? "?"
            enabled = false; save()
            disconnect()
            status = .failed(reason == "NOT_FOUND"
                             ? String(localized: "Thiết bị chưa được đăng ký cho App ID này")
                             : String(localized: "Không mở được AIUsage (\(reason))"))
        case (CastNamespace.connection, "CLOSE") where m.source == transportID:
            appGone()
        case (CastNamespace.aiusage, "hello"):
            push(force: true)
        default:
            break
        }
    }

    private func receiverStatus(_ apps: [[String: Any]]) {
        if let app = apps.first(where: { $0["appId"] as? String == appID }),
           let transport = app["transportId"] as? String {
            sessionID = app["sessionId"] as? String
            guard transport != transportID else { return }
            transportID = transport
            launchDeadline = nil
            joined = true
            launchAllowed = false
            retryDelay = 5
            send(to: transport, CastNamespace.connection, Self.connect)
            status = .showing
            lastBody = nil
            push(force: true)
            pusher?.invalidate()
            pusher = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.push(force: false) }
        } else if joined {
            appGone()
        } else if !launchAllowed {
            // Nothing to join and no fresh request from the user: casting ends here.
            appGone()
        } else if !launchSent, enabled {
            launchSent = true
            launchDeadline = Date().addingTimeInterval(30)
            status = .launching
            requestID += 1
            send(to: Self.platform, CastNamespace.receiver, ["type": "LAUNCH", "appId": appID, "requestId": requestID])
        }
    }

    /// Our app left the screen while we were showing it: someone stopped it or cast something else.
    private func appGone() {
        enabled = false
        launchAllowed = false
        save()
        disconnect()
        status = .off
        stopBrowsingIfIdle()
    }

    private func send(to destination: String, _ namespace: String, _ payload: [String: Any]) {
        channel?.send(from: Self.sender, to: destination, namespace: namespace, payload)
    }

    private func save() {
        UserDefaults.standard.set(enabled, forKey: "castEnabled")
        UserDefaults.standard.set(deviceID, forKey: "castDeviceID")
    }

    // MARK: Snapshot

    /// Sends the snapshot when it changed, and at least every 5 minutes (the screen marks
    /// the Mac as gone after 20 minutes of silence).
    private func push(force: Bool) {
        guard let transportID, status == .showing else { return }
        let now = Date()
        let body = CastSnapshot.json(CastSnapshot.build(store, now: now)) ?? ""
        guard force || body != lastBody || now.timeIntervalSince(lastPush) > 300 else { return }
        let snap = CastSnapshot.message(store, now: now)
        lastBody = body
        lastPush = now
        send(to: transportID, CastNamespace.aiusage, ["type": "snapshot", "snapshot": snap])
        // Developer aid, off unless asked for (`defaults write com.stevenlam.AIUsage castSaveSnapshot -bool true`):
        // the last snapshot sent, owner-only, for working on the receiver with real numbers
        // (cast-receiver/index.html?demo&snapshot=<url of a copy>). It holds account names and balances.
        let file = AppPaths.support + "/cast-snapshot.json"
        if UserDefaults.standard.bool(forKey: "castSaveSnapshot"),
           let data = try? JSONSerialization.data(withJSONObject: snap, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: file, contents: data, attributes: [.posixPermissions: 0o600])
        } else if FileManager.default.fileExists(atPath: file) {
            try? FileManager.default.removeItem(atPath: file)
        }
    }
}

// MARK: - One-shot push (app closed)

/// `AIUsage --cast-push`, run by the 5-minute refresh job after each fetch, so the display keeps
/// up with the widget while the app is closed. When casting is on, it joins the AIUsage session
/// already running on the chosen display, sends one snapshot and quits. It never launches the
/// receiver and never changes the casting settings: a display someone stopped stays stopped.
final class CastOneShot {
    private let deviceID: String
    private let appID: String
    private var browser: NWBrowser?
    private var channel: CastChannel?
    private var done = false
    private var outcome = "display not found"

    private init(deviceID: String, appID: String) {
        self.deviceID = deviceID
        self.appID = appID
    }

    static func run(timeout: TimeInterval = 15) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "castEnabled"), let deviceID = d.string(forKey: "castDeviceID") else { return }
        let override = d.string(forKey: "castAppID") ?? ""
        let shot = CastOneShot(deviceID: deviceID, appID: override.isEmpty ? CastController.registeredAppID : override)
        guard !shot.appID.isEmpty else { return }
        shot.browse()
        let deadline = Date().addingTimeInterval(timeout)
        while !shot.done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        FileHandle.standardError.write(Data("cast-push: \(shot.outcome)\n".utf8))
        shot.browser?.cancel()
        shot.channel?.cancel()
    }

    private func browse() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self, self.channel == nil, !self.done else { return }
                for r in results {
                    if case let .bonjour(txt) = r.metadata, txt["id"] == self.deviceID {
                        self.connect(r.endpoint)
                        return
                    }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func connect(_ endpoint: NWEndpoint) {
        browser?.cancel()
        outcome = "no reply from display"
        let ch = CastChannel(endpoint: endpoint) { [weak self] event in self?.handle(event) }
        channel = ch
        ch.start()
    }

    private func send(_ to: String, _ ns: String, _ payload: [String: Any]) {
        channel?.send(from: CastController.sender, to: to, namespace: ns, payload)
    }

    private func handle(_ event: CastChannel.Event) {
        switch event {
        case .ready:
            send(CastController.platform, CastNamespace.connection, CastController.connect)
            send(CastController.platform, CastNamespace.receiver, ["type": "GET_STATUS", "requestId": 1])
        case .closed:
            if outcome == "no reply from display" { outcome = "connection closed" }
            done = true
        case .message(let m):
            guard let json = m.json, let type = json["type"] as? String else { return }
            if m.namespace == CastNamespace.heartbeat, type == "PING" {
                send(m.source, CastNamespace.heartbeat, ["type": "PONG"])
            } else if m.namespace == CastNamespace.receiver, type == "RECEIVER_STATUS" {
                let apps = (json["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
                guard let app = apps.first(where: { $0["appId"] as? String == appID }),
                      let transport = app["transportId"] as? String else {
                    outcome = "AIUsage not on screen, nothing sent"
                    done = true          // not on screen: nothing to update, and nothing gets launched
                    return
                }
                send(transport, CastNamespace.connection, CastController.connect)
                let snap = CastSnapshot.message(DashboardStore(), now: Date())
                send(transport, CastNamespace.aiusage, ["type": "snapshot", "snapshot": snap])
                outcome = "sent"
                // Let the frames leave before the socket closes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.done = true }
            }
        }
    }
}

// MARK: - Snapshot builder

/// What the receiver draws, already localized: cards (one per service, Antigravity accounts
/// grouped in one card), the most urgent "needs attention" item, and up to two money chips.
enum CastSnapshot {
    static func json(_ v: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The snapshot as sent: `build` plus `sent`, the time of the newest fetch (shown as "updated at").
    static func message(_ s: DashboardStore, now: Date) -> [String: Any] {
        var snap = build(s, now: now)
        snap["sent"] = Int64((latestFetch(s) ?? now).timeIntervalSince1970 * 1000)
        return snap
    }

    static func latestFetch(_ s: DashboardStore) -> Date? {
        (s.subscriptions.filter(\.live).compactMap(\.fetchedAt) + [s.gemini.fetchedAt].compactMap { $0 }).max()
    }

    private static func ms(_ d: Date?) -> Any { d.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull() }

    private static func bar(_ b: BarItem, short: Bool) -> [String: Any] {
        let label = short ? (b.window == QuotaWindow.fiveHours ? String(localized: "5 giờ") : String(localized: "Tuần")) : b.label
        var d: [String: Any] = ["label": label, "value": b.value, "reset": ms(b.resetDate),
                                "window": Int(b.window), "gradient": b.gradient]
        if let t = b.valueText { d["text"] = t }
        if let n = b.note { d["note"] = n }
        return d
    }

    private static func status(_ inputs: [PaceInput], now: Date) -> Any {
        guard let p = paceStatus(inputs, now: now) else { return NSNull() }
        let level: String
        switch p.level {
        case .critical: level = "critical"
        case .fast: level = "fast"
        case .ok: level = "ok"
        }
        return ["level": level, "text": p.text]
    }

    /// Short account label for the shared screen: a name the user gave, else the part before "@".
    private static func accountName(_ p: ProviderData) -> String {
        let a = p.account
        if let at = a.firstIndex(of: "@") { return String(a[..<at]) }
        return a.isEmpty ? p.name : a
    }

    static func build(_ s: DashboardStore, now: Date) -> [String: Any] {
        var cards: [[String: Any]] = []

        for (p, brand) in [(s.claude, "claude"), (s.chatgpt, "openai")] where p.enabled && p.hasData {
            let bars = p.bars.filter(\.reported)
            var card: [String: Any] = [
                "id": p.id, "brand": brand, "name": p.name, "plan": p.plan,
                "login": p.needsLogin, "stale": isStaleFetch(p.fetchedAt, asOf: now), "fetched": ms(p.fetchedAt),
                "status": status(bars.filter { $0.window > 0 }.map(\.paceInput), now: now),
                "accounts": [["name": "", "bars": bars.map { bar($0, short: false) }]],
            ]
            // Every column is drawn as three boxes of two numbers plus a stats block, like the
            // Antigravity accounts, so the three columns share one scale on the display.
            if brand == "claude" {
                if let api = s.claudeAPI, !api.needsLogin {
                    var credit: [String: Any] = ["label": String(localized: "API credit"), "value": usd(api.balance),
                                                 "of": String(localized: "trên \(usd(api.grant))"),
                                                 "fraction": api.grant > 0 ? min(1, api.balance / api.grant) : 0]
                    if let m = api.spendMonth { credit["spent"] = usd(m); credit["spentLabel"] = String(localized: "tháng này") }
                    card["credit"] = credit
                }
                card["resetCells"] = claudeResets(s)
                let d = s.insights.day
                if s.config.providers.insights, s.insights.present, d.requests > 0 {
                    card["usage"] = ["title": "Claude Code",
                                     "stats": [["value": "\(d.requests)", "label": String(localized: "request")],
                                               ["value": "\(d.sessions)", "label": String(localized: "phiên")],
                                               ["value": "\(d.subagentHeavy)%", "label": "subagent"]]]
                }
            } else {
                let r = s.codexHist.resets
                if r.available > 0 {
                    card["resetCells"] = [["label": String(localized: "Còn lại"), "count": r.available, "expires": ms(r.next?.expires)]]
                }
                let c = s.insights.codexDay
                if s.config.providers.codex, c.turns > 0 {
                    card["usage"] = ["title": "Codex CLI",
                                     "stats": [["value": "\(c.turns)", "label": String(localized: "lượt")],
                                               ["value": tokens(c.tokens), "label": String(localized: "token")],
                                               ["value": "\(c.peakContext)%", "label": String(localized: "context max")]]]
                }
            }
            cards.append(card)
        }

        let agy = ([s.agy] + s.agyMore).filter { $0.enabled && ($0.hasData || $0.id != "antigravity") }
        if s.agy.enabled, agy.contains(where: \.hasData) {
            let multi = agy.count > 1
            let inputs = agy.filter(\.live).flatMap { p in
                p.bars.filter { $0.reported && $0.window > 0 }.map { b in
                    PaceInput(short: multi ? "\(accountName(p)) · \(b.window == QuotaWindow.fiveHours ? String(localized: "5 giờ") : String(localized: "Tuần"))" : b.label,
                              value: b.value, reset: b.resetDate, window: b.window)
                }
            }
            let main = agy.first { $0.hasData } ?? s.agy
            cards.append([
                "id": "antigravity", "brand": "gemini", "name": "Antigravity", "plan": main.plan,
                "login": !multi && main.needsLogin, "stale": isStaleFetch(main.fetchedAt, asOf: now), "fetched": ms(main.fetchedAt),
                "status": status(inputs, now: now),
                "accounts": agy.map { p in
                    ["name": multi ? accountName(p) : "", "login": p.needsLogin, "empty": !p.hasData,
                     "bars": p.bars.map { bar($0, short: multi) }] as [String: Any]
                },
            ])
        }

        var alert: Any = NSNull()
        if let a = s.attention(now: now).first(where: { $0.level != .info }) {
            alert = ["level": a.level == .critical ? "critical" : "warning", "title": a.title, "detail": a.detail]
        }

        var gemini: Any = NSNull()
        let g = s.gemini
        if s.config.providers.gemini, g.present, let bal = g.balance {
            var block: [String: Any] = [
                "title": "Gemini API", "balance": money(bal), "balanceLabel": String(localized: "Số dư credit"),
                "stats": [["value": money(g.today), "label": String(localized: "hôm nay")],
                          ["value": money(g.week), "label": String(localized: "7 ngày")],
                          ["value": money(g.month), "label": String(localized: "tháng này")]],
            ]
            if let tier = g.tier { block["tier"] = tier }
            if let days = g.runway { block["runway"] = "\(days)"; block["runwayLabel"] = String(localized: "ngày còn đủ") }
            gemini = block
        }

        let lang = (Bundle.main.preferredLocalizations.first ?? "vi").hasPrefix("en") ? "en" : "vi"
        return ["v": 3, "lang": lang, "cards": cards, "alert": alert, "gemini": gemini]
    }

    /// Banked claude.ai resets, one cell per kind (weekly first): how many, and when the first one expires.
    private static func claudeResets(_ s: DashboardStore) -> [[String: Any]] {
        let grants = s.claudeResetGrants
        guard !grants.isEmpty else {
            return s.claudeResets > 0 ? [["label": String(localized: "Còn lại"), "count": s.claudeResets, "expires": NSNull()]] : []
        }
        let kinds = grants.reduce(into: [String]()) { if !$0.contains($1.kind) { $0.append($1.kind) } }
            .sorted { ($0.lowercased() == "weekly" ? 0 : 1) < ($1.lowercased() == "weekly" ? 0 : 1) }
        return kinds.map { kind in
            let mine = grants.filter { $0.kind == kind }
            let label = kind.lowercased() == "weekly" ? String(localized: "Tuần") : kind
            return ["label": label, "count": mine.count, "expires": ms(mine.compactMap(\.expires).min())]
        }
    }
}

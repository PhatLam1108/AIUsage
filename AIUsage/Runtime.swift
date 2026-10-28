import Foundation
import AppKit
import Security

// MARK: - Paths

/// Everything AIUsage keeps outside its bundle. `AIUSAGE_HOME` redirects it to a
/// throwaway folder holding sample data, used to render the promotional
/// screenshots without touching real numbers (the installer then stays off launchd).
enum AppPaths {
    static let isSandboxHome = ProcessInfo.processInfo.environment["AIUSAGE_HOME"] != nil
    static let home = ProcessInfo.processInfo.environment["AIUSAGE_HOME"] ?? NSHomeDirectory()
    static var support: String { home + "/Library/Application Support/AIUsage" }
    static var bin: String { support + "/bin" }
    static var fetchOne: String { bin + "/fetch_one.sh" }
    static var helperApp: String { support + "/ClaudeUsageHelper.app" }
    static var helper: String { helperApp + "/Contents/MacOS/ClaudeUsageHelper" }
    static var config: String { support + "/config.json" }
    static var cache: String { home + "/.ai_usage_cache.json" }
    static var launchAgents: String { home + "/Library/LaunchAgents" }
    static var triggerFile: String { home + "/Library/Caches/ai_usage.trigger" }
    static var loginTrigger: String { home + "/Library/Caches/ai_usage_login.trigger" }
    static var versionMarker: String { support + "/.runtime-version" }
    /// The runtime shipped inside the app (scripts + helper), copied out by the installer.
    static var bundled: String? {
        guard let r = Bundle.main.resourcePath else { return nil }
        let p = r + "/runtime"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
}

// MARK: - Config

/// One SSH host whose Claude Code / Codex session logs are analysed remotely.
/// Sign-in is key-based only (BatchMode): the password is typed once, by the user,
/// in Terminal when installing the key (ssh-copy-id); AIUsage never stores it.
struct RemoteHost: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""        // label on the cards; empty = the machine's own hostname
    var host = ""        // address or ~/.ssh/config alias
    var user = ""        // empty = ssh default / ~/.ssh/config
    var port = 22
    var key = ""         // private key path; empty = ssh default / ~/.ssh/config

    enum CodingKeys: String, CodingKey { case name, host, user, port, key }
    init(host: String = "") { self.host = host }
    init(from d: Decoder) throws {
        // config.json written before 0.9 listed hosts as plain strings
        if let single = try? d.singleValueContainer(), let h = try? single.decode(String.self) {
            host = h; return
        }
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
    }
    static func == (a: RemoteHost, b: RemoteHost) -> Bool {
        a.name == b.name && a.host == b.host && a.user == b.user && a.port == b.port && a.key == b.key
    }

    var target: String { user.isEmpty ? host : "\(user)@\(host)" }
    var label: String { name.isEmpty ? host : name }
    /// Options shared by every ssh/scp call; `portFlag` is -p for ssh, -P for scp.
    func options(portFlag: String = "-p") -> [String] {
        var o = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        if port != 22 { o += [portFlag, String(port)] }
        if !key.isEmpty { o += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        return o
    }
}

/// `config.json`, shared with the fetch scripts (they read it with Python, so keys stay snake_case).
struct AppConfig: Codable, Equatable {
    struct Providers: Codable, Equatable {
        var claude = true, console = true, codex = true, agy = true, gemini = false, insights = true
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            claude = try c.decodeIfPresent(Bool.self, forKey: .claude) ?? true
            console = try c.decodeIfPresent(Bool.self, forKey: .console) ?? true
            codex = try c.decodeIfPresent(Bool.self, forKey: .codex) ?? true
            agy = try c.decodeIfPresent(Bool.self, forKey: .agy) ?? true
            gemini = try c.decodeIfPresent(Bool.self, forKey: .gemini) ?? false
            insights = try c.decodeIfPresent(Bool.self, forKey: .insights) ?? true
        }
    }
    struct Gemini: Codable, Equatable {
        var project = "", billingAccount = "", bqTable = "", currency = "VND"
        enum CodingKeys: String, CodingKey { case project, billingAccount = "billing_account", bqTable = "bq_table", currency }
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
            billingAccount = try c.decodeIfPresent(String.self, forKey: .billingAccount) ?? ""
            bqTable = try c.decodeIfPresent(String.self, forKey: .bqTable) ?? ""
            currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "VND"
        }
    }

    var providers = Providers()
    var gemini = Gemini()
    var remoteHosts: [RemoteHost] = []
    var appPath: String? = nil
    /// Set once the user has been through the Accounts window, so first launch opens it by itself.
    var onboarded = false

    enum CodingKeys: String, CodingKey { case providers, gemini, remoteHosts = "remote_hosts", appPath = "app_path", onboarded }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent(Providers.self, forKey: .providers) ?? Providers()
        gemini = try c.decodeIfPresent(Gemini.self, forKey: .gemini) ?? Gemini()
        remoteHosts = try c.decodeIfPresent([RemoteHost].self, forKey: .remoteHosts) ?? []
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath)
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: AppPaths.config) }

    /// For display: the saved config, or defaults when there is none (or it can't be read).
    static func load() -> AppConfig { loadForEditing() ?? AppConfig() }

    /// For code that will save: nil when a config exists but can't be decoded, so the
    /// caller never writes defaults over the user's settings. The unreadable file is kept
    /// aside as config.json.unreadable for recovery.
    static func loadForEditing() -> AppConfig? {
        guard let data = FileManager.default.contents(atPath: AppPaths.config) else { return AppConfig() }
        if let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) { return cfg }
        try? data.write(to: URL(fileURLWithPath: AppPaths.config + ".unreadable"))
        return nil
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: AppPaths.support, withIntermediateDirectories: true)
        // Keep the previous version: one bad write must never cost the user their settings.
        if let old = fm.contents(atPath: AppPaths.config), old != data {
            try? old.write(to: URL(fileURLWithPath: AppPaths.config + ".bak"))
        }
        let tmp = AppPaths.config + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: data) {
            _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: AppPaths.config), withItemAt: URL(fileURLWithPath: tmp))
        }
    }
}

// MARK: - Installer

/// Copies the scripts and the WebKit helper out of the app bundle into
/// Application Support and (re)registers the three LaunchAgents, so a fresh
/// Mac only needs to drag AIUsage into Applications and open it. Runs on every
/// launch but only does work when the app's version or location changed.
enum RuntimeInstaller {
    static let labelPrefix = "com.stevenlam.ai-usage-"
    private static let scripts = ["fetch_one.sh", "fetch_usage.sh", "login.sh", "remote_insights.py"]

    static var stamp: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        // The bundled scripts' timestamps too, so a rebuild with the same version still reinstalls.
        let fm = FileManager.default
        let marks = ["fetch_one.sh", "ClaudeUsageHelper.app/Contents/MacOS/ClaudeUsageHelper"].compactMap { f -> String? in
            guard let src = AppPaths.bundled,
                  let d = (try? fm.attributesOfItem(atPath: src + "/" + f))?[.modificationDate] as? Date else { return nil }
            return String(Int(d.timeIntervalSince1970))
        }
        return "\(v) (\(b)) \(Bundle.main.bundlePath) \(marks.joined(separator: "."))"
    }

    static var isCurrent: Bool {
        (try? String(contentsOfFile: AppPaths.versionMarker, encoding: .utf8)) == stamp
    }

    /// Returns an error message when installing failed; nil on success or when nothing was needed.
    @discardableResult
    static func installIfNeeded(force: Bool = false) -> String? {
        guard let src = AppPaths.bundled else { return nil }   // developer build without the bundling phase
        if !force && isCurrent && FileManager.default.isExecutableFile(atPath: AppPaths.helper) { return nil }
        do {
            try install(from: src)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func install(from src: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: AppPaths.bin, withIntermediateDirectories: true)
        for s in scripts {
            let dst = AppPaths.bin + "/" + s
            try? fm.removeItem(atPath: dst)
            try fm.copyItem(atPath: src + "/" + s, toPath: dst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
        }
        let helperSrc = src + "/ClaudeUsageHelper.app"
        if fm.fileExists(atPath: helperSrc) {
            try? fm.removeItem(atPath: AppPaths.helperApp)
            try fm.copyItem(atPath: helperSrc, toPath: AppPaths.helperApp)
        }

        // Only record where the app lives; an unreadable config is left untouched.
        if var cfg = AppConfig.loadForEditing(), cfg.appPath != Bundle.main.bundlePath {
            cfg.appPath = Bundle.main.bundlePath
            cfg.save()
        }

        if !AppPaths.isSandboxHome {
            try installAgents()
            removeLegacyScripts()
        }
        try stamp.write(toFile: AppPaths.versionMarker, atomically: true, encoding: .utf8)
    }

    /// refresh: every 5 minutes. trigger: when the app or widget asks for a refresh.
    /// login: when the widget's sign-in button is pressed.
    private static func installAgents() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: AppPaths.launchAgents, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: AppPaths.home + "/Library/Caches", withIntermediateDirectories: true)
        let bin = AppPaths.bin
        let agents: [(String, [String: Any])] = [
            ("refresh", [
                "ProgramArguments": ["/bin/bash", bin + "/fetch_usage.sh", "--scheduled"],
                "RunAtLoad": true, "StartInterval": 300,
                "StandardOutPath": "/tmp/ai-usage-refresh.log", "StandardErrorPath": "/tmp/ai-usage-refresh.err",
            ]),
            ("trigger", [
                "ProgramArguments": ["/bin/bash", bin + "/fetch_usage.sh"],
                "WatchPaths": [AppPaths.triggerFile], "AbandonProcessGroup": true,
                "StandardOutPath": "/tmp/ai_usage_trigger.log", "StandardErrorPath": "/tmp/ai_usage_trigger.err",
            ]),
            ("login", [
                "ProgramArguments": ["/bin/bash", bin + "/login.sh"],
                "WatchPaths": [AppPaths.loginTrigger],
                "StandardOutPath": "/tmp/ai-usage-login.log", "StandardErrorPath": "/tmp/ai-usage-login.err",
            ]),
        ]
        let uid = getuid()
        for (name, body) in agents {
            let label = labelPrefix + name
            var plist = body; plist["Label"] = label
            let path = AppPaths.launchAgents + "/" + label + ".plist"
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            launchctl(["bootout", "gui/\(uid)/\(label)"])
            launchctl(["bootstrap", "gui/\(uid)", path])
        }
    }

    /// Pre-0.9 builds kept the scripts in ~/Library/Scripts under these exact names.
    private static func removeLegacyScripts() {
        for n in ["ai_usage_fetch_one.sh", "ai_usage_refresh.sh", "ai_usage_remote_insights.py", "ai_usage_login.sh"] {
            try? FileManager.default.removeItem(atPath: AppPaths.home + "/Library/Scripts/" + n)
        }
    }

    static var agentsLoaded: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(labelPrefix)refresh"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}

// MARK: - Shell helpers

enum Shell {
    /// PATH that finds user-installed CLIs (codex, agy, Homebrew python) even when launched from Finder.
    static let path = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")

    /// Environment for scripts and the helper: the extended PATH, and HOME pointed at
    /// the sample-data folder when AIUSAGE_HOME is set (the scripts resolve every path from HOME).
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        if AppPaths.isSandboxHome { env["HOME"] = AppPaths.home }
        return env
    }

    /// Runs a command and returns (exit status, stdout). Blocking: call off the main thread.
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Full path of a CLI on the extended PATH, or nil when it isn't installed.
    static func which(_ name: String) -> String? {
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// `/usr/bin/python3` is only a stub until the Command Line Tools are installed.
    static var hasPython: Bool {
        if let p = which("python3"), p != "/usr/bin/python3" { return true }
        return run("/usr/bin/xcode-select", ["-p"], timeout: 5).0 == 0
    }

    /// Opens Terminal running `command`, for sign-ins that only exist as interactive CLIs.
    static func openInTerminal(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/bash\nexport PATH=\"\(path)\"\n\(command)\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}

// MARK: - Keychain (Gemini service account)

/// The Gemini service-account JSON lives in the login keychain as base64 under
/// service `aiusage.gcp.sa`; the fetch script reads it with `security`, so the
/// item lists /usr/bin/security as a trusted reader.
enum ServiceAccountStore {
    static let service = "aiusage.gcp.sa", account = "aiusage"

    static var isStored: Bool {
        Shell.run("/usr/bin/security", ["find-generic-password", "-a", account, "-s", service], timeout: 10).0 == 0
    }

    /// Validates the file as a service-account key and stores it. Returns an error message on failure.
    static func importKey(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "service_account", obj["private_key"] is String, obj["client_email"] is String
        else { return String(localized: "File này không phải khoá service account của Google Cloud.") }
        let b64 = data.base64EncodedString()
        delete()
        var access: SecAccess?
        var apps: [SecTrustedApplication] = []
        for path in [Bundle.main.bundlePath, "/usr/bin/security"] {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { apps.append(app) }
        }
        SecAccessCreate("AIUsage Gemini service account" as CFString, apps as CFArray, &access)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(b64.utf8),
        ]
        if let access { query[kSecAttrAccess as String] = access }
        let st = SecItemAdd(query as CFDictionary, nil)
        return st == errSecSuccess ? nil : (SecCopyErrorMessageString(st, nil) as String? ?? "OSStatus \(st)")
    }

    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    /// Project id inside the stored key, to prefill the Gemini project field.
    static func projectID(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["project_id"] as? String
    }
}

// MARK: - Limit resets

enum LimitReset {
    /// Spends one Codex limit-reset credit (weekly + 5-hour), the same call the Codex app
    /// makes. `requestID` makes a retried press count once. Returns the server's outcome
    /// ("reset", "already_redeemed") or throws with a readable message.
    static func consumeCodex(creditID: String) async throws -> String {
        let authPath = AppPaths.home + "/.codex/auth.json"
        guard let data = FileManager.default.contents(atPath: authPath),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String
        else { throw ResetError(String(localized: "Chưa đăng nhập Codex trên máy này.")) }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!)
        req.httpMethod = "POST"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        if let acct = tokens["account_id"] as? String { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["credit_id": creditID, "redeem_request_id": UUID().uuidString.lowercased()])
        let (body, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let msg = (json?["detail"] as? String) ?? (json?["message"] as? String) ?? String(data: body, encoding: .utf8) ?? ""
            throw ResetError("HTTP \(status) \(msg.prefix(160))")
        }
        return json?["code"] as? String ?? "ok"
    }

    struct ResetError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

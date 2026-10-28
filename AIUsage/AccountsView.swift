import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

/// State of one data source as the Accounts window sees it.
enum SourceState: Equatable {
    case connected(Date?)      // last successful fetch
    case needsLogin
    case notSetUp(String)      // what is missing, in one short sentence
    case off

    var label: LocalizedStringKey {
        switch self {
        case .connected: return "Đã kết nối"
        case .needsLogin: return "Cần đăng nhập"
        case .notSetUp: return "Chưa thiết lập"
        case .off: return "Đã tắt"
        }
    }
    var isConnected: Bool { if case .connected = self { return true } else { return false } }

    var color: Color {
        switch self {
        case .connected: return .green
        case .needsLogin: return .orange
        case .notSetUp: return .secondary
        case .off: return .secondary
        }
    }
}

/// Reads the config, the cache and the installed CLIs to tell which sources work,
/// and runs the per-source sign-in flows.
@Observable
final class AccountsModel {
    // Loaded once when the window opens; saved only on the user's own edits.
    var config = AppConfig.loadForEditing() ?? AppConfig()
    /// False when config.json exists but couldn't be read: nothing is saved over it.
    let canSave = AppConfig.loadForEditing() != nil
    var busy: Set<String> = []
    var note: [String: String] = [:]          // last action result per source
    var progress: [String: String] = [:]      // what is running right now, shown instead of the note
    private(set) var cache: [String: Any] = [:]
    private(set) var codexCLI: String? = nil
    private(set) var agyCLI: String? = nil
    private(set) var codexAuth = false
    private(set) var claudeLogs = false
    private(set) var hasPython = true
    var serviceAccount = false
    private(set) var agentsLoaded = true

    /// Refreshes statuses (cache, CLIs, keychain). The config itself is NOT re-read here:
    /// replacing it under the user's fingers would drop unsaved edits.
    func reload() {
        if let d = FileManager.default.contents(atPath: AppPaths.cache),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cache = j } else { cache = [:] }
        let home = AppPaths.home
        DispatchQueue.global(qos: .userInitiated).async {
            let codex = Shell.which("codex"), agy = Shell.which("agy")
            let auth = FileManager.default.fileExists(atPath: home + "/.codex/auth.json")
            let logs = FileManager.default.fileExists(atPath: home + "/.claude/projects")
            let py = Shell.hasPython, sa = ServiceAccountStore.isStored
            let agents = AppPaths.isSandboxHome || RuntimeInstaller.agentsLoaded
            DispatchQueue.main.async {
                self.codexCLI = codex; self.agyCLI = agy; self.codexAuth = auth; self.claudeLogs = logs
                self.hasPython = py; self.serviceAccount = sa; self.agentsLoaded = agents
            }
        }
    }

    func save() { if canSave { config.save() } }

    /// When the window opens, sources that have no numbers yet but may already be signed in
    /// on this Mac (an earlier install, an existing Codex or agy login) are fetched right away,
    /// so they turn green without the user pressing anything.
    private var probed = false
    func probeExistingSignIns() {
        guard !probed else { return }
        probed = true
        if config.providers.claude, section("claude")["session"] == nil { fetchNow("claude", source: "claude") }
        if config.providers.codex, section("codex")["session"] == nil,
           FileManager.default.fileExists(atPath: AppPaths.home + "/.codex/auth.json") { fetchNow("codex", source: "codex") }
        if config.providers.agy, section("agy")["gemini_weekly"] == nil, Shell.which("agy") != nil { fetchNow("agy", source: "agy") }
    }

    private func section(_ k: String) -> [String: Any] { cache[k] as? [String: Any] ?? [:] }
    private func fetched(_ k: String) -> Date? { parseISODate(section(k)["fetched_at"] as? String) }

    var claudeState: SourceState {
        guard config.providers.claude else { return .off }
        let c = section("claude")
        if c["needs_login"] as? Bool == true { return .needsLogin }
        if c["session"] != nil { return .connected(fetched("claude")) }
        return .notSetUp(String(localized: "Đăng nhập claude.ai một lần trong cửa sổ của AIUsage."))
    }
    var consoleState: SourceState {
        guard config.providers.console, config.providers.claude else { return .off }
        let a = section("claude")["api"] as? [String: Any] ?? [:]
        if a["needs_login"] as? Bool == true { return .needsLogin }
        if a["balance"] != nil { return .connected(fetched("claude")) }
        return .notSetUp(String(localized: "Đăng nhập Anthropic Console để thấy số dư tín dụng API."))
    }
    var codexState: SourceState {
        guard config.providers.codex else { return .off }
        if codexCLI == nil && !codexAuth { return .notSetUp(String(localized: "Chưa thấy Codex CLI trên máy này.")) }
        if !codexAuth { return .needsLogin }
        if section("codex")["session"] != nil { return .connected(fetched("codex")) }
        return .notSetUp(String(localized: "Đã đăng nhập, đang chờ lần lấy số đầu tiên."))
    }
    var agyState: SourceState {
        guard config.providers.agy else { return .off }
        if agyCLI == nil { return .notSetUp(String(localized: "Chưa thấy lệnh agy của Antigravity.")) }
        let g = section("agy")
        if g["gemini_weekly"] != nil || g["plan"] != nil { return .connected(fetched("agy")) }
        return .needsLogin
    }
    var geminiState: SourceState {
        guard config.providers.gemini else { return .off }
        let g = section("gemini")
        if g["needs_login_google"] as? Bool == true { return .needsLogin }
        if g["balance"] != nil || g["spend_est"] != nil { return .connected(fetched("gemini")) }
        if config.gemini.project.isEmpty && !serviceAccount {
            return .notSetUp(String(localized: "Đăng nhập Google AI Studio, thêm khoá service account nếu muốn có chi phí theo model."))
        }
        return .notSetUp(String(localized: "Đang chờ lần lấy số đầu tiên."))
    }
    var insightsState: SourceState {
        guard config.providers.insights else { return .off }
        if section("insights")["day"] != nil { return .connected(fetched("insights")) }
        if !claudeLogs { return .notSetUp(String(localized: "Chưa có nhật ký Claude Code trong ~/.claude.")) }
        return .notSetUp(String(localized: "Đang chờ lần phân tích đầu tiên."))
    }
    /// Last fetch result for a host: true = read just now, false = only an old copy, nil = never.
    func remoteOK(_ h: RemoteHost) -> Bool? {
        let list = section("insights")["remote"] as? [[String: Any]] ?? []
        let hit = list.first { ($0["target"] as? String) == h.host || ($0["host"] as? String) == h.label
                               || ($0["host"] as? String) == h.host }
        return hit?["ok"] as? Bool
    }

    // MARK: Actions

    /// Opens the WebKit helper in sign-in mode; when its window closes, refreshes `fetch`.
    func helperLogin(_ mode: String, source: String, fetch: String) {
        busy.insert(source)
        progress[source] = String(localized: "Đang mở cửa sổ đăng nhập…")
        DispatchQueue.global().async {
            Shell.run(AppPaths.helper, [mode], timeout: 1800)
            self.fetchNow(fetch, source: source)
        }
    }

    /// Runs one fetch in the background and reloads the status when it lands.
    func fetchNow(_ provider: String, source: String) {
        DispatchQueue.main.async {
            self.busy.insert(source)
            self.progress[source] = String(localized: "Đang lấy số liệu…")
        }
        DispatchQueue.global().async {
            Shell.run("/bin/bash", [AppPaths.fetchOne, provider], timeout: 240)
            DispatchQueue.main.async {
                self.busy.remove(source)
                self.progress[source] = nil
                self.reload()
            }
        }
    }

    func chooseServiceAccount() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Chọn file JSON khoá service account của Google Cloud")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let err = ServiceAccountStore.importKey(from: url) {
            note["gemini"] = err
        } else {
            if config.gemini.project.isEmpty, let p = ServiceAccountStore.projectID(in: url) { config.gemini.project = p }
            config.providers.gemini = true
            save()
            note["gemini"] = String(localized: "Đã lưu khoá vào Keychain.")
            serviceAccount = true
            fetchNow("gemini", source: "gemini")
        }
    }

    func addHost() { config.remoteHosts.append(RemoteHost()) }

    func removeHost(_ h: RemoteHost) {
        config.remoteHosts.removeAll { $0.id == h.id }
        save()
    }

    /// Checks key-based SSH to one host and that it has python3. Nothing is installed there:
    /// fetch_one.sh sends the analyser over the SSH session on every run.
    func setUpHost(_ h: RemoteHost) {
        guard !h.host.isEmpty else { return }
        let key = "host-" + h.id.uuidString
        busy.insert(key)
        save()
        DispatchQueue.global().async {
            let msg: String
            let (ok, _) = Shell.run("/usr/bin/ssh", h.options() + [h.target, "command -v python3 >/dev/null"], timeout: 25)
            if ok == 255 || ok == -1 {
                msg = String(localized: "Không SSH được bằng khoá. Bấm Cài khoá SSH để cài khoá lên máy này.")
            } else if ok != 0 {
                msg = String(localized: "SSH được nhưng máy này chưa có python3.")
            } else {
                msg = String(localized: "Kết nối được. Đang lấy số liệu từ máy này.")
            }
            DispatchQueue.main.async {
                self.note[key] = msg
                self.busy.remove(key)
                self.fetchNow("insights", source: key)
            }
        }
    }

    /// Opens Terminal to create a key (if the host has none) and install it with ssh-copy-id.
    /// The server password is typed there by the user, once; AIUsage never sees it.
    func installKey(for h: RemoteHost) {
        guard let i = config.remoteHosts.firstIndex(where: { $0.id == h.id }), !h.host.isEmpty else { return }
        if config.remoteHosts[i].key.isEmpty { config.remoteHosts[i].key = "~/.ssh/id_ed25519_aiusage" }
        save()
        let hh = config.remoteHosts[i]
        let keyPath = (hh.key as NSString).expandingTildeInPath
        let q: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let port = hh.port != 22 ? " -p \(hh.port)" : ""
        let start = String(localized: "AIUsage: cài khoá SSH lên \(hh.target). Nhập mật khẩu của máy chủ khi được hỏi.")
        let done = String(localized: "Xong. Quay lại AIUsage và bấm Kiểm tra.")
        Shell.openInTerminal("""
        echo \(q(start))
        [ -f \(q(keyPath)) ] || ssh-keygen -t ed25519 -N "" -C aiusage -f \(q(keyPath))
        ssh-copy-id -i \(q(keyPath + ".pub"))\(port) \(q(hh.target)) && echo \(q(done))
        """)
    }

    func reinstallRuntime() {
        busy.insert("runtime")
        DispatchQueue.global().async {
            let err = RuntimeInstaller.installIfNeeded(force: true)
            DispatchQueue.main.async {
                self.note["runtime"] = err ?? String(localized: "Đã cài lại phần chạy nền.")
                self.busy.remove("runtime"); self.reload()
            }
        }
    }
}

// MARK: - View

/// One panel per AI service: what it reads, whether it works, and how to sign in.
struct AccountsView: View {
    @State private var model = AccountsModel()
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !model.canSave {
                    Text("Không đọc được config.json nên AIUsage sẽ không ghi đè nó. Bản gốc được giữ ở config.json.unreadable; sửa hoặc xoá file rồi mở lại cửa sổ này.")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.hasPython || !model.agentsLoaded { systemPanel }
                claudePanel
                consolePanel
                codexPanel
                agyPanel
                geminiPanel
                insightsPanel
                footer
            }
            .padding(20)
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 560, idealHeight: 780)
        .navigationTitle("Tài khoản")
        .background(LinearGradient(colors: [Color.appBGTop, Color.appBG], startPoint: .top, endPoint: .bottom))
        .onAppear {
            model.reload()
            model.probeExistingSignIns()
        }
        .onReceive(ticker) { _ in if model.busy.isEmpty { model.reload() } }
        .onDisappear {
            model.config.onboarded = true
            model.save()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tài khoản").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Bật những dịch vụ bạn dùng và đăng nhập từng cái. Mật khẩu và mã xác nhận luôn do bạn tự nhập trong cửa sổ của dịch vụ; AIUsage chỉ đọc số liệu sử dụng và lưu trên máy này.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Panels

    private var systemPanel: some View {
        panel(icon: AnyView(symbolIcon("gearshape.2.fill", .gray)), title: "Phần chạy nền",
              subtitle: "Script làm mới mỗi 5 phút và khi bấm làm mới.",
              state: .notSetUp(""), toggle: nil) {
            if !model.hasPython {
                Text("Cần Python 3 từ Command Line Tools của Apple.").font(.system(size: 11.5))
                Button("Cài Command Line Tools") { Shell.run("/usr/bin/xcode-select", ["--install"], timeout: 10) }
            }
            if !model.agentsLoaded {
                Text("Lịch làm mới nền chưa chạy.").font(.system(size: 11.5))
                actionButton("Cài lại phần chạy nền", busy: "runtime") { model.reinstallRuntime() }
            }
            noteText("runtime")
        }
    }

    private var claudePanel: some View {
        panel(icon: AnyView(BrandIcon(provider: "claude", color: .claude, size: 13)), title: "Claude",
              subtitle: "Hạn mức 5 giờ và tuần, đọc từ claude.ai/settings/usage.",
              state: model.claudeState, toggle: $model.config.providers.claude) {
            HStack(spacing: 8) {
                if !model.claudeState.isConnected {
                    actionButton(signInTitle(model.claudeState, "Đăng nhập claude.ai"), busy: "claude") {
                        model.helperLogin("login", source: "claude", fetch: "claude")
                    }
                }
                refreshButton("claude", source: "claude")
            }
            if !model.claudeState.isConnected {
                hint("Chọn Continue with email; đăng nhập Google bị chặn trong cửa sổ nhúng. Dán mã xác nhận bằng Cmd+V.")
            }
            noteText("claude")
        }
    }

    private var consolePanel: some View {
        panel(icon: AnyView(BrandIcon(provider: "claude", color: .claude, size: 13)), title: "Anthropic Console",
              subtitle: "Số dư tín dụng API (gói Max tặng 200 USD mỗi tháng), đọc từ platform.claude.com.",
              state: model.consoleState, toggle: $model.config.providers.console) {
            HStack(spacing: 8) {
                if !model.consoleState.isConnected {
                    actionButton(signInTitle(model.consoleState, "Đăng nhập Console"), busy: "console") {
                        model.helperLogin("login-console", source: "console", fetch: "claude")
                    }
                }
                refreshButton("claude", source: "console")
            }
            noteText("console")
        }
    }

    private var codexPanel: some View {
        panel(icon: AnyView(BrandIcon(provider: "openai", color: .openai, size: 13)), title: "ChatGPT / Codex",
              subtitle: "Hạn mức 5 giờ và tuần, lượt reset, lịch sử 7 ngày, qua tài khoản ChatGPT của Codex.",
              state: model.codexState, toggle: $model.config.providers.codex) {
            HStack(spacing: 8) {
                if model.codexCLI == nil && !model.codexState.isConnected {
                    Link("Cài Codex CLI", destination: URL(string: "https://developers.openai.com/codex/cli")!)
                        .buttonStyle(.glass)
                } else if !model.codexState.isConnected {
                    Button("Đăng nhập trong Terminal") { Shell.openInTerminal("codex login") }
                        .buttonStyle(.glass)
                }
                refreshButton("codex", source: "codex")
            }
            if !model.codexState.isConnected {
                hint("Lệnh codex login mở trình duyệt để đăng nhập ChatGPT. Xong thì bấm làm mới.")
            }
            noteText("codex")
        }
    }

    private var agyPanel: some View {
        panel(icon: AnyView(BrandIcon(provider: "gemini", color: .geminiBlue, size: 13)), title: "Antigravity",
              subtitle: "Hạn mức Gemini và Claude+GPT trong Antigravity, đọc bằng lệnh agy.",
              state: model.agyState, toggle: $model.config.providers.agy) {
            HStack(spacing: 8) {
                if model.agyCLI == nil && !model.agyState.isConnected {
                    Link("Tải Antigravity", destination: URL(string: "https://antigravity.google")!)
                        .buttonStyle(.glass)
                } else if !model.agyState.isConnected {
                    Button("Mở agy để đăng nhập") { Shell.openInTerminal("agy") }
                        .buttonStyle(.glass)
                }
                refreshButton("agy", source: "agy")
            }
            if !model.agyState.isConnected {
                hint("Lần đầu chạy, agy hướng dẫn đăng nhập Google. Đăng nhập xong thoát agy rồi bấm làm mới.")
            }
            noteText("agy")
        }
    }

    private var geminiPanel: some View {
        panel(icon: AnyView(GeminiMark(size: 23)), title: "Gemini API",
              subtitle: "Số dư credit trên Google AI Studio; chi phí theo ngày và model khi có khoá service account.",
              state: model.geminiState, toggle: $model.config.providers.gemini) {
            HStack(spacing: 8) {
                if !model.geminiState.isConnected {
                    actionButton(signInTitle(model.geminiState, "Đăng nhập Google AI Studio"), busy: "gemini") {
                        model.helperLogin("login-aistudio", source: "gemini", fetch: "gemini")
                    }
                }
                Button(model.serviceAccount ? "Thay khoá service account…" : "Thêm khoá service account…") {
                    model.chooseServiceAccount()
                }
                .buttonStyle(.glass)
                refreshButton("gemini", source: "gemini")
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                field("Project ID", text: $model.config.gemini.project, prompt: "my-project-123")
                field("Billing account", text: $model.config.gemini.billingAccount, prompt: "0123AB-456CDE-789F01")
                field("Bảng BigQuery", text: $model.config.gemini.bqTable, prompt: "project.dataset.gcp_billing_export_v1_…")
                field("Tiền tệ", text: $model.config.gemini.currency, prompt: "VND, USD, EUR…")
            }
            .onSubmit { model.save() }
            DisclosureGroup("Hướng dẫn tạo khoá service account (5 phút)") { geminiGuide }
                .font(.system(size: 11.5))
            HStack {
                Button("Lưu") { model.save(); model.fetchNow("gemini", source: "gemini") }.buttonStyle(.glassProminent)
                hint("Bảng BigQuery là tuỳ chọn, cho chi phí chính xác (đã gồm chiết khấu cache).")
            }
            noteText("gemini")
        }
    }

    /// What a new user has to do in Google Cloud, in order, with the pages linked.
    private var geminiGuide: some View {
        VStack(alignment: .leading, spacing: 7) {
            guideStep(1, "Mở Google AI Studio, trang API keys, xem project chứa khoá API bạn đang dùng. Ghi lại Project ID (dạng gen-lang-client-0123456789).",
                      link: ("Mở AI Studio · API keys", "https://aistudio.google.com/apikey"))
            guideStep(2, "Trong Google Cloud Console, chọn đúng project đó, bật ba API: Cloud Monitoring API, Cloud Billing API, BigQuery API.",
                      link: ("Mở thư viện API", "https://console.cloud.google.com/apis/library"))
            guideStep(3, "Vào IAM & Admin > Service Accounts > Create service account. Đặt tên, ví dụ aiusage-reader.",
                      link: ("Mở Service Accounts", "https://console.cloud.google.com/iam-admin/serviceaccounts"))
            guideStep(4, "Cấp quyền chỉ đọc cho service account: Monitoring Viewer. Nếu dùng BigQuery thì thêm BigQuery Data Viewer và BigQuery Job User.", link: nil)
            guideStep(5, "Mở service account vừa tạo > tab Keys > Add key > Create new key > JSON. File JSON được tải về máy.", link: nil)
            guideStep(6, "Bấm \"Thêm khoá service account…\" ở trên và chọn file đó. AIUsage cất khoá vào Keychain và tự điền Project ID; sau đó xoá file JSON trong Downloads.", link: nil)
            guideStep(7, "Billing account (tuỳ chọn, để mở đúng tài khoản trả tiền trên AI Studio): Billing > Account management, mã dạng 0123AB-456CDE-789F01.",
                      link: ("Mở Billing", "https://console.cloud.google.com/billing"))
            guideStep(8, "Bảng BigQuery (tuỳ chọn, cho chi phí chính xác): Billing > Billing export > BigQuery export > Standard usage cost, chọn một dataset. Sau vài giờ sẽ có bảng gcp_billing_export_v1_…; điền dạng project.dataset.bảng.",
                      link: ("Mở Billing export", "https://console.cloud.google.com/billing/export"))
            Text("Khoá chỉ có quyền đọc số liệu, không tạo hay xoá được gì. Có thể thu hồi bất cứ lúc nào ở tab Keys.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func guideStep(_ n: Int, _ text: LocalizedStringKey, link: (LocalizedStringKey, String)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).frame(width: 16)
                .foregroundStyle(.white).background(Circle().fill(Color.geminiBlue).frame(width: 16, height: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                if let link, let url = URL(string: link.1) {
                    Link(link.0, destination: url).font(.system(size: 11))
                }
            }
        }
    }

    private var insightsPanel: some View {
        panel(icon: AnyView(symbolIcon("chart.bar.xaxis", .claude)), title: "Phân tích Claude Code và Codex",
              subtitle: "Đọc nhật ký phiên trên máy này, trong Cowork và trên máy chủ từ xa qua SSH. Không cần đăng nhập.",
              state: model.insightsState, toggle: $model.config.providers.insights) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Máy chủ từ xa (SSH)").font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Button { model.addHost() } label: { Label("Thêm máy chủ", systemImage: "plus") }
                        .buttonStyle(.glass).controlSize(.small)
                }
                ForEach($model.config.remoteHosts) { $h in hostRow($h) }
                hint("Mỗi máy chủ đăng nhập bằng khoá SSH riêng, không lưu mật khẩu. Chưa có khoá thì bấm Cài khoá SSH: Terminal mở ra để bạn nhập mật khẩu máy chủ một lần. Có thể điền tên trong ~/.ssh/config vào ô Địa chỉ.")
            }
        }
    }

    private func hostRow(_ h: Binding<RemoteHost>) -> some View {
        let key = "host-" + h.wrappedValue.id.uuidString
        let ok = model.remoteOK(h.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(ok == true ? Color.green : ok == false ? Color.orange : Color.secondary).frame(width: 7, height: 7)
                TextField("", text: h.name, prompt: Text("Tên (tuỳ chọn)")).frame(width: 120)
                TextField("", text: h.host, prompt: Text("Địa chỉ hoặc alias"))
                TextField("", text: h.user, prompt: Text("user")).frame(width: 90)
                TextField("", value: h.port, format: .number.grouping(.never), prompt: Text("22")).frame(width: 52)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.save() }
            HStack(spacing: 6) {
                Text(h.wrappedValue.key.isEmpty ? String(localized: "Khoá: mặc định của ssh") : h.wrappedValue.key)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Chọn khoá…") { chooseKey(h) }.buttonStyle(.link).font(.system(size: 10.5))
                Spacer()
                Button("Cài khoá SSH…") { model.installKey(for: h.wrappedValue) }.buttonStyle(.glass).controlSize(.small)
                actionButton("Kiểm tra", busy: key) { model.setUpHost(h.wrappedValue) }.controlSize(.small)
                Button { model.removeHost(h.wrappedValue) } label: { Image(systemName: "trash") }
                    .buttonStyle(.glass).controlSize(.small).help("Xoá máy chủ này")
            }
            Text(ok == true ? "Đang đọc được." : ok == false ? "Chỉ còn số cũ: lần gần nhất không kết nối được." : "Chưa có dữ liệu.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            noteText(key)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func chooseKey(_ h: Binding<RemoteHost>) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Chọn file khoá riêng (private key) dùng cho máy chủ này")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        h.wrappedValue.key = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        model.save()
    }

    private var footer: some View {
        HStack {
            Text("Cấu hình lưu ở ~/Library/Application Support/AIUsage/config.json")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
            Button("Mở thư mục") { NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.support)) }
                .buttonStyle(.link).font(.system(size: 10.5))
        }
    }

    // MARK: Building blocks

    private func panel<Content: View>(icon: AnyView, title: LocalizedStringKey, subtitle: LocalizedStringKey,
                                      state: SourceState, toggle: Binding<Bool>?,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                        statusPill(state)
                    }
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let toggle {
                    Toggle("", isOn: Binding(get: { toggle.wrappedValue },
                                             set: { toggle.wrappedValue = $0; model.save() }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            if case .notSetUp(let why) = state, !why.isEmpty {
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if toggle?.wrappedValue ?? true {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14, brand: .clear)
    }

    /// "Sign in" until it works, then "Switch account" (sign out inside the window to change it).
    private func signInTitle(_ state: SourceState, _ first: LocalizedStringKey) -> LocalizedStringKey {
        state == .needsLogin ? "Đăng nhập lại" : first
    }

    private func statusPill(_ s: SourceState) -> some View {
        HStack(spacing: 4) {
            Circle().fill(s.color).frame(width: 6, height: 6)
            Text(s.label).font(.system(size: 10.5, weight: .medium))
            if case .connected(let at?) = s {
                Text("· " + at.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(s.color.opacity(0.12)))
    }

    private func actionButton(_ title: LocalizedStringKey, busy key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if model.busy.contains(key) { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .buttonStyle(.glassProminent)
        .disabled(model.busy.contains(key))
    }

    private func refreshButton(_ provider: String, source: String) -> some View {
        Button { model.fetchNow(provider, source: source) } label: {
            if model.busy.contains(source) { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
        }
        .buttonStyle(.glass)
        .help("Lấy số ngay")
        .disabled(model.busy.contains(source))
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
        }
    }

    private func hint(_ t: LocalizedStringKey) -> some View {
        Text(t).font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func noteText(_ key: String) -> some View {
        if let p = model.progress[key] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(p).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if let n = model.note[key], !n.isEmpty {
            Text(n).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func symbolIcon(_ name: String, _ color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient)
            Image(systemName: name).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 23, height: 23)
    }
}

/// The Gemini API mark used on its card and in the Accounts window.
struct GeminiMark: View {
    var size: CGFloat = 21
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(LinearGradient(colors: [.geminiBlue, .geminiPurple, .geminiPink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkles").font(.system(size: size * 0.52, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

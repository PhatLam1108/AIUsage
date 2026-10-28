// ClaudeUsageHelper — read usage pages that only exist behind a browser login,
// by loading them in a native WKWebView (Safari engine) with a persisted session.
//
//   ClaudeUsageHelper login            -> window; log into claude.ai once
//   ClaudeUsageHelper fetch            -> hidden; dump claude.ai/settings/usage innerText
//   ClaudeUsageHelper login-aistudio   -> window; log into Google once (AI Studio)
//   ClaudeUsageHelper fetch-aistudio   -> hidden; dump aistudio.google.com/billing innerText
//   ClaudeUsageHelper login-console / fetch-console -> same for platform.claude.com (API credits)
//
// Parsing is done by the shell/Python caller so it's easy to tweak. All modes
// share WKWebsiteDataStore.default() (same bundle id), so cookies saved at login
// are reused by every later fetch — no OAuth token, no CLI, no rate-limited API.
// Exit codes: 0 = dumped, 2 = timed out (partial dump), 3 = needs login.

import AppKit
import WebKit

let SAFARI_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

struct Site {
    let url: URL
    let title: String
    let readyMarkers: [String]     // lowercased innerText substrings = data has rendered
    let loginURLMarkers: [String]  // lowercased URL substrings = bounced to a login page
    let loginTextMarkers: [String] // lowercased innerText substrings = login form shown
    var frameHost: String? = nil        // also dump the innerText of a cross-origin iframe from this host
    var frameReadyMarker: String? = nil // ...once that frame's text contains this (lowercased)
    var expandJS: String? = nil         // run once when the data is ready, BEFORE the dump (opens collapsed sections)
}

/// Vietnamese when the system prefers it, English otherwise (the helper is built
/// with swiftc outside Xcode, so it has no string catalog of its own).
let isVietnamese = Locale.preferredLanguages.first?.hasPrefix("vi") ?? false
func L(_ vi: String, _ en: String) -> String { isVietnamese ? vi : en }

let SITES: [String: Site] = [
    "claude": Site(
        url: URL(string: "https://claude.ai/settings/usage")!,
        title: L("Đăng nhập Claude, xong thì đóng cửa sổ này", "Sign in to Claude, then close this window"),
        readyMarkers: ["% used", "resets"],
        loginURLMarkers: ["/login"],
        loginTextMarkers: ["log in"]),
    // Anthropic Console (API platform): credit balance, monthly spend vs tier limit.
    // Separate origin from claude.ai, so it has its own sign-in (once).
    "console": Site(
        url: URL(string: "https://platform.claude.com/dashboard")!,
        title: L("Đăng nhập Anthropic Console, xong thì đóng cửa sổ này", "Sign in to the Anthropic Console, then close this window"),
        readyMarkers: ["organization credits"],
        loginURLMarkers: ["/login", "/logout"],
        loginTextMarkers: ["continue with email", "log in", "sign in"]),
    "aistudio": Site(
        url: URL(string: "https://aistudio.google.com/billing")!,
        title: L("Đăng nhập Google (AI Studio), xong thì đóng cửa sổ này", "Sign in to Google (AI Studio), then close this window"),
        // The balance card is a payments.google.com iframe — the main document
        // never contains "credit balance", so readiness is the tier line, and
        // the iframe's own text is appended to the dump.
        readyMarkers: ["billing account tier cap", "credit balance"],
        loginURLMarkers: ["accounts.google.com"],
        loginTextMarkers: ["sign in", "choose an account"],
        frameHost: "payments.google.com",
        frameReadyMarker: "credit balance"),
]

final class Helper: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    let isLogin: Bool
    let site: Site
    var webView: WKWebView!
    var window: NSWindow!
    var tries = 0
    var finalized = false
    var jsRan = false
    var expanded = false
    var targetFrame: WKFrameInfo?   // the cross-origin iframe we also want to read
    var frameTries = 0

    init(isLogin: Bool, site: Site) { self.isLogin = isLogin; self.site = site }

    // In login mode, quit as soon as the user closes the login window so the
    // launching app can detect completion (Process.waitUntilExit) and refresh.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { isLogin }

    // A bare WKWebView in a window with NO main menu has no ⌘C/⌘V/⌘X/⌘A/⌘Z at all
    // (the key equivalents live in the Edit menu), which made typing an email or a
    // sign-in code into the login window painful. Login mode installs a minimal
    // App / Edit / Window menu wired to the first responder (= the web view).
    func installMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let host = NSMenuItem(); main.addItem(host)
            let m = NSMenu(title: title); items.forEach { m.addItem($0) }; host.submenu = m
        }
        func item(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; return i
        }
        submenu("Claude Usage Helper", [
            item(L("Ẩn Claude Usage Helper", "Hide Claude Usage Helper"), #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item(L("Thoát", "Quit"), #selector(NSApplication.terminate(_:)), "q")])
        submenu(L("Chỉnh sửa", "Edit"), [
            item(L("Hoàn tác", "Undo"), Selector(("undo:")), "z"),
            item(L("Làm lại", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cắt", "Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Sao chép", "Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Dán", "Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Chọn tất cả", "Select All"), #selector(NSText.selectAll(_:)), "a")])
        submenu(L("Trang", "Page"), [
            item(L("Tải lại", "Reload"), #selector(reload), "r"),
            item(L("Đóng cửa sổ", "Close Window"), #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = main
    }
    @objc func reload() { webView.reload() }

    func applicationDidFinishLaunching(_ note: Notification) {
        if isLogin {
            installMenu()
            // LSUIElement hides the Dock icon; give the login window one (and an
            // app icon in ⌘-Tab) so it can be found and brought to the front.
            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let img = NSImage(contentsOfFile: path) {
                NSApp.applicationIconImage = img
            }
        }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // persistent + shared across runs
        // Google sign-in opens helper popups (window.open) during "this may take
        // a moment"; a WKWebView with no UI delegate silently drops them and the
        // flow hangs forever. Allow popups and route them into this same view.
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 820)
        webView = WKWebView(frame: frame, configuration: cfg)
        webView.customUserAgent = SAFARI_UA
        webView.navigationDelegate = self
        webView.uiDelegate = self

        if isLogin {
            window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.title = isOpen ? L("Dùng lượt reset ở mục Limit resets. Xong thì đóng cửa sổ này.", "Use a reset under Limit resets, then close this window.") : site.title
            window.contentView = webView
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Hidden, off-screen window so WebKit still renders the SPA.
            window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = webView
            // Nearly transparent but ON-screen: an off-screen/alpha-0 window makes WebKit
            // report visibilityState=hidden, which parks requestAnimationFrame and keeps
            // some SPAs (the Anthropic Console) from ever rendering.
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.setFrameOrigin(NSPoint(x: 0, y: 0))
            window.orderFront(nil)
            // Hard cap so a stuck load never hangs the LaunchAgent.
            let cap: Double = ProcessInfo.processInfo.environment["AIUSAGE_JS"] == nil ? 35 : 70
            DispatchQueue.main.asyncAfter(deadline: .now() + cap) { [weak self] in
                self?.finish(dumpAnyway: true, code: 2)
            }
        }
        webView.load(URLRequest(url: site.url))
    }

    // window.open -> load in the same web view (Google's sign-in popups only
    // need to run, not to be a separate window).
    func webView(_ wv: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { wv.load(navigationAction.request) }
        return nil
    }

    // Remember the iframe we want to read (payments widget) as it navigates —
    // WKFrameInfo from here is what evaluateJavaScript(in:) needs to target it.
    func webView(_ wv: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let host = site.frameHost, let f = navigationAction.targetFrame, !f.isMainFrame,
           navigationAction.request.url?.host?.contains(host) == true {
            targetFrame = f
        }
        decisionHandler(.allow)
    }

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        guard !isLogin else { watchSignedIn(); return }
        // The numbers arrive via XHR after the page loads, so poll the text.
        pollScrape()
    }

    // Login mode: once the page shows the data the fetch needs, the user is signed
    // in (often already, from an earlier session). Say so and close by ourselves so
    // the app can fetch right away instead of waiting for the window to be closed.
    var signedInShown = false
    func watchSignedIn(_ attempt: Int = 0) {
        guard !isOpen, !signedInShown, attempt < 20 else { return }
        webView.evaluateJavaScript("document.body.innerText") { [weak self] r, _ in
            guard let self, !self.signedInShown else { return }
            let low = ((r as? String) ?? "").lowercased()
            if self.site.readyMarkers.contains(where: { low.contains($0) }) {
                self.signedInShown = true
                self.window.title = L("Đã đăng nhập. Cửa sổ sẽ tự đóng…", "Signed in. This window will close…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.window.close() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.watchSignedIn(attempt + 1) }
            }
        }
    }

    func pollScrape() {
        if finalized { return }
        tries += 1
        webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
            guard let self = self, !self.finalized else { return }
            let text = (result as? String) ?? ""
            let low = text.lowercased()
            let url = self.webView.url?.absoluteString.lowercased() ?? ""
            let ready = self.site.readyMarkers.contains { low.contains($0) }

            if !ready && (self.site.loginURLMarkers.contains { url.contains($0) }
                          || self.site.loginTextMarkers.contains { low.contains($0) }) {
                FileHandle.standardError.write(Data("NEEDLOGIN\n".utf8))
                self.finish(dumpAnyway: false, code: 3)
                return
            }
            // AIUSAGE_JS: once the page has rendered something, run this async
            // script ONCE (it may click around / navigate), then keep polling
            // for the ready markers as usual. Used to switch AI Studio to the
            // right billing account before reading the page.
            if let js = ProcessInfo.processInfo.environment["AIUSAGE_JS"], !js.isEmpty, !self.jsRan, (self.tries >= 3 || ready), (!low.isEmpty || self.tries >= 8) {
                self.jsRan = true
                self.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { res in
                    if case .failure(let e) = res { FileHandle.standardError.write(Data("JSERR \(e)\n".utf8)) }
                    // Whatever happened (incl. a navigation killing the script), resume polling.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pollScrape() }
                }
                return
            }
            if ready, let js = self.site.expandJS, !self.expanded {
                self.expanded = true
                self.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { _ in
                    // Give the opened section a moment to render, then dump as usual.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.pollScrape() }
                }
                return
            }
            if ready {
                // Got data. Wait once more so every section has settled, then dump.
                self.finalized = true   // stop further polling; the delayed dump exits
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.dumpAll() }
                return
            }
            if self.tries > (ProcessInfo.processInfo.environment["AIUSAGE_JS"] == nil ? 25 : 55) {
                self.finish(dumpAnyway: true, code: 0)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pollScrape() }
        }
    }

    // Print the main document text, plus the target iframe's text (retrying a
    // few seconds for it to render) when the site asks for one.
    func dumpAll() {
        webView.evaluateJavaScript("document.body.innerText") { [weak self] r, _ in
            guard let self = self else { exit(0) }
            let main = (r as? String) ?? ""
            guard self.site.frameHost != nil else { print(main); exit(0) }
            guard let frame = self.targetFrame else {
                // The main page reports ready before the payments iframe has even
                // started loading — give it up to ~20s to show up.
                if self.frameTries >= 20 { print(main); exit(0) }
                self.frameTries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.dumpAll() }
                return
            }
            self.webView.evaluateJavaScript("document.body.innerText", in: frame, in: .page) { res in
                let ft = (try? res.get()) as? String ?? ""
                let marker = self.site.frameReadyMarker ?? ""
                if (marker.isEmpty || ft.lowercased().contains(marker)) || self.frameTries >= 15 {
                    print(main + "\n===FRAME===\n" + ft)
                    exit(0)
                }
                self.frameTries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.dumpAll() }
            }
        }
    }

    func finish(dumpAnyway: Bool, code: Int32) {
        // Where did we end up? (a silent redirect to a login page is the usual reason for an empty dump)
        FileHandle.standardError.write(Data("FINISH url=\(webView.url?.absoluteString ?? "nil") title=\(webView.title ?? "") code=\(code)\n".utf8))
        if dumpAnyway {
            webView.evaluateJavaScript("document.body.innerText") { r, _ in
                if let t = r as? String { print(t) }
                exit(code)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(code) }
        } else {
            exit(code)
        }
    }
}

// "login" / "fetch" keep their original meaning (claude); "-aistudio" suffix
// selects the Google AI Studio billing page.
let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "login"
let parts = arg.split(separator: "-", maxSplits: 1).map(String.init)
// "open" shows the page like "login" but never closes by itself: the user acts on
// the page (e.g. spends a limit reset on claude.ai) and closes the window when done.
let isOpen = parts[0] == "open"
let isLogin = parts[0] == "login" || isOpen
var site = SITES[parts.count > 1 ? parts[1] : "claude"] ?? SITES["claude"]!
// AIUSAGE_URL overrides the page to load (same site rules) — lets the caller
// pass query params such as the billing account without rebuilding.
if let u = ProcessInfo.processInfo.environment["AIUSAGE_URL"], let url = URL(string: u) {
    site = Site(url: url, title: site.title, readyMarkers: site.readyMarkers,
                loginURLMarkers: site.loginURLMarkers, loginTextMarkers: site.loginTextMarkers,
                frameHost: site.frameHost, frameReadyMarker: site.frameReadyMarker, expandJS: site.expandJS)
}
let app = NSApplication.shared
let helper = Helper(isLogin: isLogin, site: site)
app.delegate = helper
app.setActivationPolicy(isLogin ? .regular : .accessory)
app.run()

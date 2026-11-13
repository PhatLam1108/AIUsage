import SwiftUI
import WidgetKit

@main
struct AIUsageApp: App {
    init() {
        // Headless reload mode: the refresh LaunchAgent runs this after updating
        // the cache. Reloading from the app's own bundle context is reliable —
        // unlike the sandboxed widget extension, which gets killed before its
        // own reloadAllTimelines can fire. Exits before any window is shown.
        if CommandLine.arguments.contains("--reload-widget") {
            WidgetCenter.shared.reloadAllTimelines()
            // Spin the run loop (NOT Thread.sleep) so the async XPC reload request
            // is actually delivered to WidgetKit before we exit.
            RunLoop.main.run(until: Date().addingTimeInterval(1.8))
            exit(0)
        }
        // Headless Cast mode: the refresh job runs this after each fetch so the Nest Hub follows the
        // widget while the app is closed. Joins the session already on screen, sends, exits.
        if CommandLine.arguments.contains("--cast-push") {
            CastOneShot.run()
            exit(0)
        }
        // Copy the bundled scripts and helper into Application Support and register the
        // background jobs; a no-op unless this build or its location is new.
        DispatchQueue.global(qos: .utility).async { RuntimeInstaller.installIfNeeded() }
        // Show the dashboard on the Cast display again if it was on when the app quit.
        DispatchQueue.main.async { CastController.shared.resume() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Screenshot tooling: AIUSAGE_APPEARANCE=light|dark pins the appearance.
                    if let a = ProcessInfo.processInfo.environment["AIUSAGE_APPEARANCE"] {
                        NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua)
                    }
                }
        }
        // Standard titled window + transparent toolbar. Height is pinned to the
        // screen by ScreenHugger; width is the user's (remembered).
        .windowResizability(.automatic)
        .windowBackgroundDragBehavior(.enabled)
        // No frame restoration: ScreenHugger sizes the window on every launch.
        .restorationBehavior(.disabled)
        .defaultSize(width: AppLayout.width, height: 600)

        // Accounts: one panel per AI service (Cmd+, and the person icon in the toolbar).
        Settings {
            AccountsView()
        }
    }
}

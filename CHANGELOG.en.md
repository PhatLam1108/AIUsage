# Changelog - AIUsage

Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/). 0.9.0 is the first public release (with a DMG installer); earlier versions were for personal use and were reconstructed from the commit history by development milestone. Vietnamese version: [CHANGELOG.md](CHANGELOG.md).

## [0.9.0] - 2026-10-28
First public release: a DMG installer that works on any Mac, a bilingual interface, an Accounts window with a panel per source, and a completely redesigned single-screen interface.

### Added - Installation and configuration
- An `AIUsage-<version>.dmg` installer for both Apple Silicon and Intel, packaged by `scripts/build-dmg.sh`. The script strips the binaries and refuses to package a build that still contains paths from the build machine.
- The app installs its background runtime on first launch and whenever the build changes (`RuntimeInstaller`): fetch scripts, the sign-in helper and 3 LaunchAgents in `~/Library/Application Support/AIUsage`. No more copying scripts by hand.
- Per-machine settings in `config.json` in that folder: source switches, Gemini settings, SSH hosts. A `config.json.bak` copy is written before every save, and an unreadable file is never overwritten.
- The **Accounts** window (`Cmd+,`): one panel per source with connection status, a sign-in button (hidden once signed in) and an on/off switch. It opens by itself on first launch.
- SSH hosts configured one by one: name, address, user, port, key; an **Install SSH key** button that opens Terminal to type the server password once; a **Check** button.
- A Gemini API panel: Project ID, billing account, BigQuery table and a service account key file (stored in the Keychain), with an 8-step guide to creating the key. Any billing currency is supported.

### Added - Dashboard
- A **Needs attention** strip at the top, built from data already fetched: quotas close to the limit or projected to run out before the reset, limit resets left, sources that need signing in again, stale data, a Gemini balance that only lasts a few more days, unusual spending, unreachable SSH hosts. Each item has an action button.
- New quota tiles: percentage used, time to reset, distance from the even pace (points ahead or behind) and the hourly or daily rate that still avoids hitting the limit before the reset.
- A button to spend a Codex limit reset (calls `rate-limit-reset-credits/consume`, always confirms first, spends the credit that expires first) and a list of credits with their expiry. Claude: limit resets left and a button that opens claude.ai's reset page. Buttons hide when nothing is left.
- Claude's per-model weekly limits (for example Fable) are back in the app and widget, read from the JSON of the usage API that the claude.ai page uses.
- The `AIUSAGE_RANGE=week` environment variable for screenshots of the 7-day view.
- A bilingual English and Vietnamese interface for the app, the widget and the helper's sign-in windows (String Catalogs, with English singular and plural forms), following the macOS language.
- The MIT license (`LICENSE`) with a Vietnamese translation (`LICENSE.vi.md`).

### Changed
- Completely redesigned interface: one screen with no tabs, three continuous columns by company (Claude, OpenAI, Google), each reading top to bottom as quotas, money and resets, analytics, heat map. Flat bars, no glow or heavy shadows.
- Claude figures come from the usage API JSON (`five_hour`, `seven_day`, `weekly_scoped`) rather than only the page text, which remains as a fallback.
- Scripts moved to `runtime/` and are bundled into the app at build time; the helper is built in a build phase for each architecture. No more hard-coded constants (Google Cloud project, billing account, host names, fixed time zone).
- The host analyser is sent over the SSH session on every run; hosts only need `python3`.
- Tighter widget spacing so the Fable row fits (measured offline: 336 of 345 points).
- Non-VND amounts use the international format (`$84.20`) whatever the system region. Times follow the Mac's time zone.

### Removed
- The `launchd/` folder, the scripts at the repository root and the prebuilt helper in the repository (replaced by the runtime bundled in the app).

### Fixed
- SSH hosts with an empty user field were parsed with shifted columns (the key path became the port, `Bad port`), because bash `read` merges consecutive tabs. Fields are now separated by `\x1f`.
- Claude Code analytics stopped on a division by zero when a session had no weighted requests.
- After signing in to Claude the status still said signed out: the sign-in window now closes by itself once the page is signed in, and the app fetches right after.

## [0.8.0] - 2026-10-23
Anthropic Console API credit replaces the Fable bar, and the helper's sign-in window is completed.

### Added
- An `API $199.69` row in the Claude card (app and widget): the API credit balance on the Anthropic Console. The Max plan grants USD 200 of API credit every month and refills it on renewal. The bar shows the percentage used and the balance sits in the label; there is no pace marker or countdown because the Console does not publish the refill date.
- The helper reads `platform.claude.com/dashboard` through two new modes, `login-console` and `fetch-console`. `fetch_one.sh claude` reads this page in parallel with the claude.ai usage page and stores the result under the `claude.api` key: balance, month-to-date spend, tier limit and reset date, prompt-cache hit rate and 7-day token volume. When the session expires, the last known values are kept and `needs_login` is set.
- The helper's sign-in window now has an application icon and an **Edit** menu (Undo, Redo, Cut, Copy, Paste, Select All), so the confirmation code sent by email can be pasted.
- The `AIUSAGE_HOME` (points the cache and scripts at a folder of sample data) and `AIUSAGE_APPEARANCE` (`light` or `dark`) environment variables, for rendering promotional images without exposing real figures.
- `CHANGELOG.en.md`, the English edition of this changelog.

### Changed
- The app version (`MARKETING_VERSION`) is set to 0.8.0 to match the documentation.
- `README.md` and `README.en.md` carry a version line, Console sign-in instructions and links to both changelogs.

### Removed
- The Fable bar from the app and the widget. The claude.ai usage page collapses the "This week" section, so the bar could not be read reliably.

### Fixed
- The background helper placed its window off screen, so WebKit reported `visibilityState=hidden` and the Anthropic Console (Next.js) never rendered, leaving `innerText` empty. The window now sits on screen at 99% transparency and ignores mouse events.
- Ad-hoc signing of the helper failed with `resource fork, Finder information, or similar detritus not allowed` when the sources lived in Documents (the File Provider attaches extended attributes). The build procedure now signs a copy in a temporary directory.

## [0.7.0] - 2026-10-19
Documentation and cleanup in preparation for GitHub.

### Added
- `README.md` (Vietnamese, default), `README.en.md`, `CHANGELOG.md` and the logo under `docs/brand/`.
- A `launchd/` directory with three sample LaunchAgents (using `__HOME__` in place of a user path) and the sign-in launcher script, so the setup can be reproduced on another machine.
- The earlier engineering notes moved to `docs/DEVELOPMENT.md`.

### Removed
- `gen_project.py`, an obsolete project generator (the project file is now managed by Xcode).
- A `__pycache__` directory committed by mistake; `__pycache__/` and `*.pyc` were added to `.gitignore`.

## [0.6.0] - 2026-10-06
### Added
- **Codex limit reset credits.** Codex grants reset credits (for both the weekly and the 5-hour limit) that expire after 30 days. The ChatGPT card shows "N resets left, expiring ..." together with the number used in the last 30 days, and the Codex limit card records the number of resets under "By week".

## [0.5.0] - 2026-09-30
### Added
- **Codex server-side data** (new `codexhist` source), the same API the Codex app's Analytics tab uses, covering every device and place of use:
  - History of the 5-hour and weekly limits for the last 7 days, with the share by model and by source; red when the cap was hit, and the title states "cap reached N/M times".
  - A "Codex by day and model" grid: the four most-used models over 7 days.

### Changed
- The two Codex panels computed from local files (by model and folder, by hour) were replaced by the two server-data panels above. The "Codex CLI" card is kept.

## [0.4.0] - 2026-09-29
Wider data sources and a redesigned dashboard layout.

### Added
- **Cowork sessions** are counted in the Claude analysis (read from the Claude Desktop session logs).
- **Remote hosts over SSH.** Claude Code and Codex sessions that run in VS Code Remote-SSH live on the server, not on the Mac. `remote_insights.py` runs on that host, reads incrementally (a few seconds the first time, under a second afterwards) and returns compressed JSON; when the connection is lost the previous result is used and the footer says "(stale)".
- **Detailed Codex view:** a token bar split into input, cache, output and reasoning; turn outcomes (completed, failed, interrupted); activity (shell commands, file edits, MCP, web search); by model, source and folder; an hourly chart. The Codex analysis is a single file shared by the Mac and the remote host so the two cannot drift apart.
- **Gemini by model, with a forecast:** percentage of spend per model, an end-of-month projection at the current pace, the number of days the balance will last and the daily average. A 30-day spend calendar was added.
- **Equal-cell grid charts** (hour of day, Gemini spend calendar) replace the bar charts; cells darken with usage and an outlined cell marks the current moment.
- The window grows to **full screen height** (down to the Dock, or full screen without a Dock), can be resized freely in both directions and remembers its width. On a short display the content scales down evenly instead of being clipped, and resizing no longer stutters.

### Changed
- The dashboard is a 4-row by 3-column grid of equal cells (Claude, Codex, Gemini); cells in the same row share one height.

### Fixed
- **Gemini:** a BigQuery export delayed by several days made "today" and "7 days" show 0. Days without an exact figure now use the Cloud Monitoring estimate and the label reads "exact up to ...". Top-up invoices (which belong to no project) are no longer added to monthly spend.
- **Widget:** the refresh button needed two presses because launchd killed the process that reloads the widget when the script exited; it now runs synchronously with `AbandonProcessGroup`.
- Numbers in the hourly cells are no longer truncated ("5...").

## [0.3.0] - 2026-09-27
Dashboard window and the Gemini API.

### Added
- **Gemini API (Google AI Studio):** credit balance and the latest top-up read from the Billing page through the helper (the balance lives in a payments.google.com iframe), cost and tokens by model from Cloud Monitoring, exact cost from the BigQuery billing export when available, and progress toward the next tier.
- **Dashboard window:** quota bars, "What is eating the Claude quota" (sessions longer than 8 hours, context above 150k, subagents), by model and project, an hourly chart, Codex and the Gemini API. A "Today" or "7 days" switch.
- **Codex reads the SQLite store of version 0.155:** counts real turns (previously every model response was counted, overstating usage more than 20 times) and detects sessions that are open but have sent no turn. The card distinguishes "no turns in this period" from "Codex not found".

### Changed
- The widget keeps exactly 17 pt of margin on each edge, measured on an off-screen render instead of estimated; the data-timestamp clock is back, and the refresh button sits beside the time on the Claude card.
- The helper allows popup windows (`window.open`) so Google sign-in no longer hangs.

## [0.2.0] - 2026-09-26
Interface and reliability rework.

### Added
- **Pace forecast:** a marker on each quota bar and a status line ("comfortable", "expected to run out ...", "N% left"); each app's real logo replaces the redrawn one.
- **Background refresh every 5 minutes.** Scheduled runs do not force a widget redraw, to stay within the WidgetKit budget; only the button does.
- **Per-source staleness warning:** each source has its own fetch timestamp and a card warns after 90 minutes (previously a single shared warning was hidden by a source that was still healthy).
- The countdown ticks every second below one hour; the widget shows "resetting" once the reset time has passed.

### Fixed
- The Claude parser follows the usage page's new labels (`Your usage`, `Current session`, `This week`, `Fable this week`); the Fable label and the Gemini version update themselves when the vendor changes them.
- Codex changed its API format: windows are now classified by length rather than by name, including the fallback that reads the log files.
- The `agy` command no longer kills the user's own Antigravity sessions: it only shuts down the language server started by the fetch itself.

## [0.1.0] - 2026-08-26
First release.

### Added
- A macOS app and a large widget (SwiftUI, WidgetKit, Liquid Glass) showing the percentage used and the reset time for Claude, ChatGPT/Codex and Antigravity.
- Data architecture: one independent fetch per source, writing to a shared cache file (atomic write, file lock); the app and widget only read the cache.
- Claude is read from `claude.ai/settings/usage` through a signed-in WKWebView helper; Codex through the `wham/usage` API; Antigravity through `agy /usage`.
- Light and dark appearance follow the system; the widget refresh button works through an App Intent and a LaunchAgent that watches a trigger file.
- The `_fresh` flag: only a genuinely successful fetch advances the shared clock; parser errors go to `/tmp/ai_usage_err.log`.

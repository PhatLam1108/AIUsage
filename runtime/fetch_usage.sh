#!/bin/bash
# Refresh ALL providers in parallel (used by LaunchAgent background refresh).
# Each provider writes its own result into the shared cache as soon as it finishes.
# Sources switched off in the Accounts window return immediately (fetch_one.sh checks config.json).
DIR="$(cd "$(dirname "$0")" && pwd)"
ONE="$DIR/fetch_one.sh"

bash "$ONE" claude &
bash "$ONE" codex &
bash "$ONE" agy &
bash "$ONE" gemini &
bash "$ONE" codexhist &
bash "$ONE" insights &
wait

cat "$HOME/.ai_usage_cache.json" 2>/dev/null

# Force a widget redraw ONLY for on-demand refreshes (widget/app button via the
# trigger LaunchAgent). The scheduled 5-min run passes --scheduled and skips it:
# 288 forced reloads/day would blow WidgetKit's ~40-70/day budget and freeze the
# widget (the chronod trap in the README). The widget's own timeline re-reads
# the cache every 5 min anyway, so scheduled data still shows up on its own.
#
# NOT backgrounded: under the trigger LaunchAgent, launchd kills whatever is
# left in the job's process group the moment this script exits, and the
# reload helper needs ~2s of run loop to deliver its XPC request. With `&` the
# reload was killed every time — the widget only showed fresh data on a SECOND
# press (WidgetKit reloads the timeline after any button intent, and by then
# the cache from the first press was already fresh).
if [ "$1" != "--scheduled" ]; then
  # The installer records where the app lives (it may not be in /Applications).
  APP_PATH="$(python3 -c 'import json,os,sys; print(json.load(open(sys.argv[1])).get("app_path",""))' \
              "$HOME/Library/Application Support/AIUsage/config.json" 2>/dev/null)"
  APP="${APP_PATH:-/Applications/AIUsage.app}/Contents/MacOS/AIUsage"
  [ -x "$APP" ] && "$APP" --reload-widget >/dev/null 2>&1
fi

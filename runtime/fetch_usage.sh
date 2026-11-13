#!/bin/bash
# Refresh ALL providers in parallel (used by LaunchAgent background refresh).
# Each provider writes its own result into the shared cache as soon as it finishes.
# Sources switched off in the Accounts window return immediately (fetch_one.sh checks config.json).
DIR="$(cd "$(dirname "$0")" && pwd)"
ONE="$DIR/fetch_one.sh"

# When the cache was last written, to tell afterwards whether this run brought anything new.
stamp() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("updated_at",""))' "$HOME/.ai_usage_cache.json" 2>/dev/null; }
BEFORE="$(stamp)"

bash "$ONE" claude &
bash "$ONE" codex &
bash "$ONE" agy &
bash "$ONE" gemini &
bash "$ONE" codexhist &
bash "$ONE" insights &
wait

cat "$HOME/.ai_usage_cache.json" 2>/dev/null

# Redraw the widget right after every run that brought new data, so the widget and the Cast
# display change together. The widget's own timeline only re-reads the cache every 15 minutes as
# a fallback: left to its own 5-minute clock it ran out of step with this job and showed each new
# number up to 5 minutes late. Measured on macOS 27 (chronod log): 316 reloads a day served,
# none refused, so one reload per run (288 a day) stays below what the widget already did.
# A scheduled run that fetched nothing new (offline, every source off) skips the reload.
#
# NOT backgrounded: under the trigger LaunchAgent, launchd kills whatever is
# left in the job's process group the moment this script exits, and the
# reload helper needs ~2s of run loop to deliver its XPC request. With `&` the
# reload was killed every time — the widget only showed fresh data on a SECOND
# press (WidgetKit reloads the timeline after any button intent, and by then
# the cache from the first press was already fresh).
# The installer records where the app lives (it may not be in /Applications).
APP_PATH="$(python3 -c 'import json,os,sys; print(json.load(open(sys.argv[1])).get("app_path",""))' \
            "$HOME/Library/Application Support/AIUsage/config.json" 2>/dev/null)"
APP="${APP_PATH:-/Applications/AIUsage.app}/Contents/MacOS/AIUsage"

if [ "$1" != "--scheduled" ] || [ "$(stamp)" != "$BEFORE" ]; then
  [ -x "$APP" ] && "$APP" --reload-widget >/dev/null 2>&1
fi

# Keep the Cast display (Nest Hub) in step with the widget, on every run, app open or not: when
# casting is on, the app joins the AIUsage session already on the display, sends the new numbers
# and quits. It never launches anything there. Not backgrounded, for the launchd reason above.
if [ "$(defaults read com.stevenlam.AIUsage castEnabled 2>/dev/null)" = "1" ]; then
  [ -x "$APP" ] && "$APP" --cast-push >/dev/null 2>&1
fi

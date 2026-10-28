#!/bin/bash
# Triggered by the widget's sign-in button (WatchPaths on the login trigger file):
# opens the claude.ai sign-in window, then refreshes Claude usage.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HOME/Library/Application Support/AIUsage/ClaudeUsageHelper.app/Contents/MacOS/ClaudeUsageHelper"
[ -x "$HELPER" ] && "$HELPER" login
bash "$DIR/fetch_one.sh" claude

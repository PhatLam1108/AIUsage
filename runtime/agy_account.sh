#!/bin/bash
# Extra Antigravity accounts. The agy CLI keeps one sign-in, in the login keychain
# (service "gemini", account "antigravity"). Each extra account gets its own HOME
# under Application Support with its own keychain, so agy started with that HOME
# reads and writes a separate token and never touches the main account.
#
# Usage: agy_account.sh {prepare|login|remove} <id>
#   prepare  create the account folder and keychain if needed, then unlock it
#   login    prepare, then run agy interactively in that HOME (from Terminal)
#   remove   delete the account's keychain, folder and keychain password
#
# The account keychain is named agy.keychain-db, never login.keychain-db: macOS
# unlocks a keychain called "login" with the user's own password, and asks for it
# in a dialog. Its random password sits in the real login keychain under
# aiusage.agy.<id>, written and read only through /usr/bin/security.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

ACTION="$1"
ID="$2"
case "$ID" in
  ""|*[!A-Za-z0-9_-]*) echo "agy_account.sh: bad account id" >&2; exit 2 ;;
esac

AIU_SUPPORT="${AIUSAGE_SUPPORT:-$HOME/Library/Application Support/AIUsage}"
ACC_HOME="$AIU_SUPPORT/agy/$ID"
KC="$ACC_HOME/Library/Keychains/agy.keychain-db"
SVC="aiusage.agy.$ID"

# The keychain password from the real login keychain; created on first use.
kc_password() {
  local pw
  pw=$(security find-generic-password -a aiusage -s "$SVC" -w 2>/dev/null)
  if [ -z "$pw" ]; then
    pw=$(openssl rand -hex 24)
    security add-generic-password -U -a aiusage -s "$SVC" -w "$pw" -T /usr/bin/security >/dev/null 2>&1 || return 1
  fi
  printf '%s' "$pw"
}

prepare() {
  mkdir -p "$ACC_HOME/Library/Keychains" "$ACC_HOME/Library/Preferences" || return 1
  chmod 700 "$ACC_HOME"
  local pw
  pw=$(kc_password) || { echo "agy_account.sh: cannot store the keychain password" >&2; return 1; }
  if [ ! -f "$KC" ]; then
    HOME="$ACC_HOME" security create-keychain -p "$pw" "$KC" || return 1
    # No auto-lock: a locked keychain would make agy (or macOS) ask for a password.
    HOME="$ACC_HOME" security set-keychain-settings "$KC"
  fi
  # Search list and default keychain are per HOME (Library/Preferences of the account).
  HOME="$ACC_HOME" security list-keychains -d user -s "$KC"
  HOME="$ACC_HOME" security default-keychain -d user -s "$KC"
  HOME="$ACC_HOME" security unlock-keychain -p "$pw" "$KC"
}

case "$ACTION" in
prepare)
  prepare
  ;;
login)
  prepare || exit 1
  AGY="$(command -v agy)"
  [ -z "$AGY" ] && { echo "agy not found. Install Antigravity first." >&2; exit 1; }
  # Same working folder as the background fetch, so the folder trust is asked once.
  cd "$ACC_HOME" || exit 1
  HOME="$ACC_HOME" "$AGY"
  ;;
remove)
  if [ -f "$KC" ]; then
    HOME="$ACC_HOME" security delete-keychain "$KC" 2>/dev/null
  fi
  security delete-generic-password -a aiusage -s "$SVC" >/dev/null 2>&1
  case "$ACC_HOME" in
    "$AIU_SUPPORT"/agy/?*) rm -rf "$ACC_HOME" ;;
  esac
  # Drop the account's numbers from the cache.
  python3 - "agy_$ID" << 'PYEOF'
import json, os, sys, fcntl
cache = os.path.expanduser('~/.ai_usage_cache.json')
with open(cache + '.lock', 'w') as lf:
    fcntl.flock(lf, fcntl.LOCK_EX)
    try:
        data = json.load(open(cache))
    except Exception:
        sys.exit(0)
    if data.pop(sys.argv[1], None) is not None:
        tmp = cache + '.tmp'
        json.dump(data, open(tmp, 'w'), indent=2)
        os.replace(tmp, cache)
PYEOF
  ;;
*)
  echo "usage: agy_account.sh {prepare|login|remove} <id>" >&2; exit 2
  ;;
esac

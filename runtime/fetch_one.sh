#!/bin/bash
# Fetch ONE provider's usage and merge it into the combined cache atomically.
# Usage: fetch_one.sh {claude|codex|codexhist|agy|gemini|insights}
# Each provider runs independently so the UI can update whichever finishes first.
#
# Runtime layout (installed by the app on first launch, see RuntimeInstaller.swift):
#   ~/Library/Application Support/AIUsage/bin/        this script and its siblings
#   ~/Library/Application Support/AIUsage/config.json providers on/off, Gemini project, remote hosts
#   ~/Library/Application Support/AIUsage/ClaudeUsageHelper.app  WebKit helper (web sign-ins)
#   ~/.ai_usage_cache.json                             merged result read by the app and widget

# LaunchAgents and GUI-launched apps get a minimal PATH that lacks ~/.local/bin
# and Homebrew, so `claude`/`agy` aren't found. Add them explicitly.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

PROVIDER="$1"
[ -z "$PROVIDER" ] && { echo "usage: fetch_one.sh {claude|codex|codexhist|agy|gemini|insights}" >&2; exit 1; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
AIU_SUPPORT="${AIUSAGE_SUPPORT:-$HOME/Library/Application Support/AIUsage}"
AIU_CONFIG="$AIU_SUPPORT/config.json"
HELPER="$AIU_SUPPORT/ClaudeUsageHelper.app/Contents/MacOS/ClaudeUsageHelper"
# IANA name of the Mac's time zone: day buckets and BigQuery dates follow the user's clock.
TZNAME="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"
[ -z "$TZNAME" ] && TZNAME="UTC"
export TZNAME

# cfg <dotted.key> [default] -> value from config.json (bools as 1/0, lists space-joined)
cfg() {
  python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
if d is None or d == "": print(sys.argv[3] if len(sys.argv) > 3 else "")
elif isinstance(d, bool): print("1" if d else "0")
elif isinstance(d, list): print(" ".join(str(x) for x in d))
else: print(d)' "$AIU_CONFIG" "$1" "$2"
}

# A source switched off in the Accounts window is skipped entirely: the cache
# keeps whatever it had and the app shows the card as not connected.
SWITCH="$PROVIDER"; [ "$SWITCH" = "codexhist" ] && SWITCH="codex"
[ "$(cfg "providers.$SWITCH" 1)" = "0" ] && exit 0

# Keep the parser error log bounded (it's appended on every run).
ERRLOG=/tmp/ai_usage_err.log
if [ -f "$ERRLOG" ] && [ "$(stat -f%z "$ERRLOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -c 65536 "$ERRLOG" > "$ERRLOG.tmp" && mv "$ERRLOG.tmp" "$ERRLOG"
fi

TMPDIR_USAGE=$(mktemp -d)
trap "rm -rf $TMPDIR_USAGE" EXIT

FRAGMENT=""

case "$PROVIDER" in

claude)
  # Fetch Claude usage by scraping the logged-in claude.ai/settings/usage page
  # with a native WKWebView helper (Safari engine). No OAuth token, no CLI, no
  # rate-limited API endpoint -> survives claude CLI updates and heavy use.
  # One-time login is done via:  ClaudeUsageHelper.app  (login mode).
  # Per-run temp file (NOT a fixed /tmp path): the app's refresh button and the
  # 30-min LaunchAgent can fetch the same provider concurrently — a shared path
  # would let them clobber each other's raw dump mid-parse.
  RAW="$TMPDIR_USAGE/claude_web_raw.txt"
  HELPER_RC=0
  # The Anthropic Console (API platform) dashboard is read in parallel: it holds
  # the monthly API credit that comes with the Max plan.
  RAW_API="$TMPDIR_USAGE/console_raw.txt"
  API_RC=0
  if [ -x "$HELPER" ]; then
    API_PID=""
    if [ "$(cfg providers.console 1)" = "1" ]; then
      "$HELPER" fetch-console > "$RAW_API" 2>/dev/null &
      API_PID=$!
    fi
    # Besides the page text, ask claude.ai's own usage API (same session) for the
    # structured numbers: exact reset times and the per-model weekly limits (Fable)
    # that the page tucks into a collapsed section.
    AIUSAGE_JS='const org=(document.cookie.match(/lastActiveOrg=([^;]+)/)||[])[1];
try{const j=await (await fetch("/api/organizations/"+org+"/usage")).json();
const p=document.createElement("pre");p.textContent="\n===USAGEJSON===\n"+JSON.stringify(j)+"\n===END===\n";document.body.appendChild(p);}catch(e){}' \
      "$HELPER" fetch > "$RAW" 2>/dev/null
    HELPER_RC=$?
    if [ -n "$API_PID" ]; then wait $API_PID; API_RC=$?; fi
  fi

  FRAGMENT=$(CLAUDE_HELPER_RC="$HELPER_RC" CLAUDE_RAW="$RAW" CLAUDE_API_RAW="$RAW_API" CLAUDE_API_RC="$API_RC" python3 2>> /tmp/ai_usage_err.log << 'PYEOF2'
import json, os, re
from datetime import datetime, timedelta, timezone
LOCAL = datetime.now().astimezone().tzinfo   # the Mac's zone: the helper renders times in it
WD = {'mon':0,'tue':1,'wed':2,'thu':3,'fri':4,'sat':5,'sun':6}

def prev_claude():
    try:
        return json.load(open(os.path.expanduser("~/.ai_usage_cache.json"))).get("claude", {})
    except Exception:
        return {}

text = ""
raw_path = os.environ.get("CLAUDE_RAW", "")
if raw_path and os.path.exists(raw_path):
    text = open(raw_path, encoding="utf-8", errors="replace").read()
# The usage API's JSON rides along at the end of the dump; split it off the page text.
usage = None
m = re.search(r"===USAGEJSON===\s*(\{.*?\})\s*===END===", text, re.S)
if m:
    try: usage = json.loads(m.group(1))
    except Exception: usage = None
    text = text[:m.start()] + text[m.end():]
lines = [l.strip() for l in text.split('\n')]
low = text.lower()

def parse_reset(s):
    s = s.strip()
    if re.search(r'\bin\b', s):
        d=re.search(r'(\d+)\s*day',s); h=re.search(r'(\d+)\s*(?:hr|hour)',s); mm=re.search(r'(\d+)\s*min',s)
        days=int(d.group(1)) if d else 0; hrs=int(h.group(1)) if h else 0; mins=int(mm.group(1)) if mm else 0
        if days or hrs or mins:
            return (datetime.now(timezone.utc)+timedelta(days=days,hours=hrs,minutes=mins)).strftime('%Y-%m-%dT%H:%M:%SZ')
    wm=re.search(r'\b(mon|tue|wed|thu|fri|sat|sun)',s,re.I); tm=re.search(r'(\d{1,2}):(\d{2})\s*([ap]m)',s,re.I)
    if wm and tm:
        hh=int(tm.group(1)); mn=int(tm.group(2)); ap=tm.group(3).lower()
        if ap=='pm' and hh!=12: hh+=12
        if ap=='am' and hh==12: hh=0
        now=datetime.now(LOCAL); ahead=(WD[wm.group(1).lower()]-now.weekday())%7
        cand=now.replace(hour=hh,minute=mn,second=0,microsecond=0)+timedelta(days=ahead)
        if cand<=now: cand+=timedelta(days=7)
        return cand.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    if tm and not wm:
        # 2026-09: page shows only a clock time for the session bar ("Resets at 6:10 PM")
        hh=int(tm.group(1)); mn=int(tm.group(2)); ap=tm.group(3).lower()
        if ap=='pm' and hh!=12: hh+=12
        if ap=='am' and hh==12: hh=0
        now=datetime.now(LOCAL)
        cand=now.replace(hour=hh,minute=mn,second=0,microsecond=0)
        if cand<=now: cand+=timedelta(days=1)
        return cand.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    return ""

def grab(label):
    # Prefix match with a short-suffix allowance so "Fable" still hits if the
    # page relabels the bar to "Fable 5" / "Fable 5.1". The length cap keeps
    # sentence lines ("Fable 5 is still included with...") from matching, and
    # a candidate only wins if a "% used" line actually follows it.
    lab = label.lower()
    for i,l in enumerate(lines):
        ll = l.lower()
        if ll == lab or (ll.startswith(lab) and len(l) <= len(label) + 6):
            pct=reset=None
            for j in range(i+1,min(i+5,len(lines))):
                pm=re.search(r'(\d{1,3})%\s*used',lines[j])
                if pm and pct is None: pct=int(pm.group(1))
                if 'reset' in lines[j].lower() and reset is None: reset=parse_reset(lines[j])
            if pct is not None:
                return pct,reset
    return None,None

# Plan name follows the "Plan usage limits" header (e.g. "Max (5x)", "Pro").
plan=""
for i,l in enumerate(lines):
    if l.lower() in ("plan usage limits","your usage"):  # 2026-09 page: "Your usage" -> "Max (20x)"
        for j in range(i+1,min(i+3,len(lines))):
            if lines[j]: plan=lines[j]; break
        break
if plan:
    m=re.match(r'(.+?)\s*\((\d+x)\)', plan)        # "Max (5x)" -> "MAX 5x"
    plan = f"{m.group(1).upper()} {m.group(2)}" if m else plan.upper()

sp,sr=grab("Current session")
wp,wr=grab("All models")
if wp is None: wp,wr=grab("This week")   # 2026-09 relabel

# Structured numbers win when the API answered: exact resets_at instead of "Thu 1:20 AM".
def iso_utc(v):
    try: return datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except Exception: return ""
scoped = []
if isinstance(usage, dict):
    fh, sd = usage.get("five_hour") or {}, usage.get("seven_day") or {}
    if fh.get("utilization") is not None: sp, sr = round(fh["utilization"]), iso_utc(fh.get("resets_at") or "")
    if sd.get("utilization") is not None: wp, wr = round(sd["utilization"]), iso_utc(sd.get("resets_at") or "")
    # Per-model weekly limits ("Fable" on Max plans), labelled by the API's display name.
    for l in usage.get("limits") or []:
        if l.get("kind") != "weekly_scoped": continue
        sc = l.get("scope") or {}
        name = ((sc.get("model") or {}).get("display_name")) or ((sc.get("surface") or {}).get("display_name"))
        if name and l.get("percent") is not None:
            scoped.append({"label": name, "pct": round(l["percent"]), "reset": iso_utc(l.get("resets_at") or "")})
# (No Fable bar any more — dropped 2026-10-22; the row now shows the API credit.)

# Anthropic Console dashboard (platform.claude.com): "Organization credits $199.69",
# "Spend this month $0.31 of $500 tier limit resets Nov 1", prompt-caching hit rate
# and 7-day token volume. The Max plan grants $200 of API credit every month.
API_GRANT = 200.0
def parse_api():
    p = os.environ.get("CLAUDE_API_RAW", "")
    t = open(p, encoding="utf-8", errors="replace").read() if p and os.path.exists(p) else ""
    t = re.sub(r'[\ue000-\uf8ff]', '', t)     # icon-font glyphs the page puts on their own lines
    prev = prev_claude().get("api") or {}
    if os.environ.get("CLAUDE_API_RC") == "3" or (t and "organization credits" not in t.lower()
            and any(k in t.lower() for k in ("continue with email", "log in", "sign in"))):
        prev = dict(prev); prev["needs_login"] = True
        return prev
    m = re.search(r'Organization credits\s*\n\s*(?:US)?\$\s*([\d,]+(?:\.\d+)?)', t, re.I)
    if not m: return prev or None          # transient miss: keep last known
    bal = float(m.group(1).replace(',', ''))
    api = {"balance": bal, "grant": max(API_GRANT, bal), "needs_login": False}
    m = re.search(r'Spend this month.*?\$\s*([\d,]+(?:\.\d+)?)\s*\n\s*of\s*\$\s*([\d,]+(?:\.\d+)?)\s*tier limit\s*\n?\s*resets\s+([A-Za-z]+)\s+(\d{1,2})', t, re.I | re.S)
    if m:
        api["spend_month"] = float(m.group(1).replace(',', '')); api["tier_limit"] = float(m.group(2).replace(',', ''))
        try:
            mon = datetime.strptime(m.group(3)[:3].title(), '%b').month; now = datetime.now(LOCAL)
            d = datetime(now.year, mon, int(m.group(4)), tzinfo=timezone.utc)
            if d < now - timedelta(days=2): d = d.replace(year=now.year + 1)
            api["tier_resets"] = d.strftime('%Y-%m-%dT%H:%M:%SZ')
        except Exception: pass
    m = re.search(r'(\d+)%\s*hit rate', t)
    if m: api["cache_hit"] = int(m.group(1))
    m = re.search(r'Token volume.*?\n([\d\.,]+)([KMB]?)\s*\n\s*last 7 days', t, re.I | re.S)
    if m: api["tokens_7d"] = round(float(m.group(1).replace(',', '')) * {"": 1, "K": 1e3, "M": 1e6, "B": 1e9}[m.group(2).upper()])
    return api
api = parse_api()

# "Limit resets" on the usage page: limit-reset grants with an expiry. With none the
# section reads "No resets right now"; otherwise each grant shows its own "Expires …".
def parse_resets():
    i = text.find("Limit resets")
    if i < 0: return None
    sec = text[i + len("Limit resets"):]
    for stop in ("Cloud session credits", "Extra usage", "Usage credits", "Included credit"):
        j = sec.find(stop)
        if j >= 0: sec = sec[:j]
    if "no resets right now" in sec.lower(): return {"available": 0}
    m = re.search(r"(\d+)\s+resets?\b", sec, re.I)
    n = int(m.group(1)) if m else max(1, len(re.findall(r"\bexpires?\b", sec, re.I)))
    return {"available": n, "detail": " ".join(sec.split())[:200]}
resets = parse_resets()

rc = os.environ.get("CLAUDE_HELPER_RC","0")
login_markers = ("continue with google","continue with email","error logging you in","log in to claude")
needs_login = (rc=="3") or (any(m in low for m in login_markers) and "% used" not in low)

if sp is not None and wp is not None:
    # Good capture. "api" is absent until the Console has been signed in once.
    # "_fresh" tells the merge step this is real new data (it bumps updated_at);
    # the prev-cache branches below omit it so the clock never lies.
    frag={"session":sp,"weekly":wp,"plan":plan or "MAX 5x",
          "session_reset":sr or "","weekly_reset":wr or "","needs_login":False,
          "_fresh":True}
    if api: frag["api"] = api
    if scoped: frag["scoped"] = scoped
    if resets is not None: frag["resets"] = resets
    print(json.dumps(frag))
elif needs_login:
    # Session expired -> keep last values but flag for the login button.
    prev=prev_claude(); prev["needs_login"]=True
    print(json.dumps(prev))
else:
    # Transient miss -> leave cache untouched.
    prev=prev_claude()
    print(json.dumps(prev) if prev else "{}")
PYEOF2
)
  ;;

codex)
  CODEX_TOKEN=$(python3 -c "
import json
try:
    d = json.load(open('$HOME/.codex/auth.json'))
    print(d.get('tokens', {}).get('access_token', ''))
except Exception:
    print('')
" 2>/dev/null)

  echo '{}' > "$TMPDIR_USAGE/codex.json"
  if [ -n "$CODEX_TOKEN" ]; then
    curl -s --max-time 4 \
      -H "Authorization: Bearer $CODEX_TOKEN" \
      "https://chatgpt.com/backend-api/wham/usage" \
      -o "$TMPDIR_USAGE/codex.json" 2>/dev/null
  fi

  FRAGMENT=$(python3 2>> /tmp/ai_usage_err.log << PYEOF
import json, os
try:
    codex = json.load(open("$TMPDIR_USAGE/codex.json"))
except Exception:
    codex = {}
from datetime import datetime, timezone, timedelta
def epoch_to_iso(w):
    ts = w.get('reset_at') or w.get('resets_at')
    if not ts:
        secs = w.get('reset_after_seconds')
        if secs is not None:
            ts = datetime.now(timezone.utc).timestamp() + secs
    try:
        return datetime.fromtimestamp(float(ts), timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except Exception:
        return ""
def roll(iso, hours):
    # Stale reset (e.g. from an old rollout) -> roll to the next window boundary.
    if not iso:
        return iso
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        if dt <= now:
            p = timedelta(hours=hours)
            dt = dt + p * (int((now - dt) / p) + 1)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return iso
rl = codex.get('rate_limit') or {}
# 2026-07: OpenAI reshuffled the windows — primary_window became the 7-DAY
# window (limit_window_seconds=604800) and secondary_window turned null. The
# old primary→session mapping crashed on None and silently froze the cache.
# Classify each window by its actual duration instead of trusting its name.
windows = [w for w in (rl.get('primary_window'), rl.get('secondary_window')) if w]
if windows:
    session = weekly = None
    s_reset = w_reset = ""
    for w in windows:
        secs = w.get('limit_window_seconds') or 0
        if secs >= 3 * 86400:          # multi-day window -> weekly bar
            if weekly is None:
                weekly = round(w.get('used_percent', 0))
                w_reset = roll(epoch_to_iso(w), 168)
        else:                           # short window -> 5-hour bar
            if session is None:
                session = round(w.get('used_percent', 0))
                s_reset = roll(epoch_to_iso(w), 5)
    frag = {
        # -1 = window doesn't exist anymore -> UI shows a dash, not a fake 0%.
        "session": session if session is not None else -1,
        "weekly": weekly if weekly is not None else -1,
        "plan": (codex.get('plan_type') or 'plus').upper(),
        "session_reset": s_reset,
        "weekly_reset": w_reset,
        "_fresh": True,
    }
    print(json.dumps(frag))
else:
    # API blocked/empty (chatgpt.com often refuses non-browser clients).
    # Fall back to the most recent rate_limits the Codex CLI itself logged
    # into its session rollouts — refreshes whenever Codex is actually used.
    import glob, re
    best = None  # (mtime, rate_limits dict)
    files = sorted(glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/*.jsonl")),
                   key=lambda f: os.path.getmtime(f), reverse=True)
    for f in files[:40]:
        latest = None
        try:
            with open(f) as fh:
                for line in fh:
                    if '"primary"' in line and 'used_percent' in line:
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        stack = [obj]
                        while stack:
                            cur = stack.pop()
                            if isinstance(cur, dict):
                                if 'primary' in cur and isinstance(cur.get('primary'), dict) \
                                   and 'used_percent' in cur['primary']:
                                    latest = cur
                                stack.extend(cur.values())
                            elif isinstance(cur, list):
                                stack.extend(cur)
        except Exception:
            continue
        if latest is not None:
            best = (os.path.getmtime(f), latest)
            break  # files are mtime-sorted; first hit is the freshest

    if best:
        rlx = best[1]
        # Same rule as the API branch: classify by window length, never by
        # the "primary"/"secondary" name (OpenAI swapped them once already).
        session = weekly = None
        s_reset = w_reset = ""
        for w in (rlx.get('primary'), rlx.get('secondary')):
            if not isinstance(w, dict):
                continue
            mins = w.get('window_minutes') or 0
            if mins >= 3 * 1440:
                if weekly is None:
                    weekly = round(w.get('used_percent', 0))
                    w_reset = roll(epoch_to_iso(w), 168)
            elif mins > 0:
                if session is None:
                    session = round(w.get('used_percent', 0))
                    s_reset = roll(epoch_to_iso(w), 5)
        frag = {
            "session": session if session is not None else -1,
            "weekly": weekly if weekly is not None else -1,
            "plan": (rlx.get('plan_type') or 'plus').upper(),
            "session_reset": s_reset,
            "weekly_reset": w_reset,
        }
        print(json.dumps(frag))
    else:
        try:
            prev = json.load(open(os.path.expanduser("~/.ai_usage_cache.json"))).get("codex", {})
            print(json.dumps(prev))
        except Exception:
            print("{}")
PYEOF
)
  ;;

agy)
  # Per-run log path (see the claude note above re concurrent fetches).
  export AGY_LOG="$TMPDIR_USAGE/agy_usage_raw.log"
  # Snapshot language servers that already exist (e.g. an agy session the user
  # has open in a terminal) so the cleanup below never touches them.
  LS_PATTERN="Resources/bin/language_server.*antigravity-cli"
  LS_BEFORE=" $(pgrep -f "$LS_PATTERN" | tr '\n' ' ') "
  # Drive the agy CLI exactly like a human: wait until the prompt is ready,
  # type /usage, and quit the instant the quota panel has rendered.
  # Pattern-matching (not fixed sleeps) keeps this as fast as doing it by hand (~5s).
  /usr/bin/expect << 'EXPEOF' > /dev/null 2>&1
set rows 40
set cols 120
stty rows $rows columns $cols
spawn -noecho agy
set agypid [exp_pid]
stty rows $rows columns $cols < $spawn_out(slave,name)
log_file -noappend $env(AGY_LOG)
set timeout 25
# Wait until agy finished starting up and shows the prompt footer (~2s).
expect -re "shortcuts"
# The plan tier "(Google AI Pro)" loads async a moment after sign-in and is
# painted onto the banner. Wait for it (best-effort) so the parser can read the
# real plan instead of falling back to a default.
set timeout 6
expect -re {Google [A-Za-z]}
send "/usage\r"
# Each of the 4 quota buckets renders a "NN.NN%" bar. Wait for the 1st (agy
# fetches over the network, variable), then the other 3 follow within ~1s; quit
# as soon as all 4 are in. The completeness check guards partial captures.
set timeout 15
expect -re {[0-9]+\.[0-9]+%}
set timeout 3
expect -re {[0-9]+\.[0-9]+%}
expect -re {[0-9]+\.[0-9]+%}
expect -re {[0-9]+\.[0-9]+%}
sleep 1
exec kill -9 $agypid
exit 0
EXPEOF
  # Reap only the language server(s) THIS fetch spawned (orphaned when expect
  # kill -9'd agy). A blanket pkill used to kill the user's own agy sessions.
  for pid in $(pgrep -f "$LS_PATTERN"); do
    case "$LS_BEFORE" in *" $pid "*) ;; *) kill -9 "$pid" 2>/dev/null ;; esac
  done

  FRAGMENT=$(python3 2>> /tmp/ai_usage_err.log << 'PYEOF'
import json, os, re
from datetime import datetime, timezone, timedelta

vals = {"gemini_5h": 0, "gemini_weekly": 0, "claude_gpt_5h": 0, "claude_gpt_weekly": 0}
resets = {"gemini_5h_reset": "", "gemini_weekly_reset": "",
          "claude_gpt_5h_reset": "", "claude_gpt_weekly_reset": ""}
g_plan = "AI PRO"
ok = False
matched = set()   # which buckets were actually read from the panel

def parse_refresh(text):
    # "Refreshes in 93h 49m" / "Refreshes in 3 days, 21 hours" / "45m"
    m = re.search(r'Refreshes in\s+(.+)', text)
    if not m:
        return ""
    s = m.group(1)
    days = hours = mins = 0
    d = re.search(r'(\d+)\s*(?:d|day|days)', s);   days = int(d.group(1)) if d else 0
    h = re.search(r'(\d+)\s*(?:h|hour|hours)', s);  hours = int(h.group(1)) if h else 0
    mm = re.search(r'(\d+)\s*(?:m|min|minutes)', s); mins = int(mm.group(1)) if mm else 0
    if days == hours == mins == 0:
        return ""
    when = datetime.now(timezone.utc) + timedelta(days=days, hours=hours, minutes=mins)
    return when.strftime('%Y-%m-%dT%H:%M:%SZ')

log = os.environ.get("AGY_LOG", "")
if log and os.path.exists(log) and os.path.getsize(log) > 100:
    raw = open(log, 'rb').read().decode('utf-8', errors='replace')
    clean = re.sub(r'\x1b\[\?[0-9;]*[a-zA-Z$]', '', raw)
    clean = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', clean)
    clean = re.sub(r'\x1b\[>[0-9;]*[a-zA-Z]', '', clean)
    clean = re.sub(r'\x1b\[=[0-9;]*[a-zA-Z]', '', clean)
    clean = re.sub(r'\x1b[()][0-9A-B]', '', clean)
    clean = re.sub(r'\x1b[>=<]', '', clean)
    clean = re.sub(r'\x1b', '', clean)
    clean = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', clean)
    lines = [l.strip() for l in clean.split('\n') if l.strip()]

    for line in lines:
        m = re.search(r'\(Google (.+?)\)', line)
        if m:
            g_plan = m.group(1).upper(); break

    # Gemini model version, read from the banner ("Gemini 3.7 Flash ...") so the
    # UI label tracks Google's version bumps (3.5 -> 3.7 -> ...) automatically.
    g_ver = ""
    for line in lines:
        m = re.search(r'Gemini\s+(\d+(?:\.\d+)?)', line)
        if m:
            g_ver = m.group(1); break
    # Banner is async and occasionally missed — never write an empty version
    # over a good cached one (an empty string broke the UI label to "Gem  · 5h").
    if not g_ver:
        try:
            g_ver = json.load(open(os.path.expanduser("~/.ai_usage_cache.json"))).get("agy", {}).get("gemini_ver", "")
        except Exception:
            pass

    group = None
    for i, line in enumerate(lines):
        if 'GEMINI MODELS' in line.upper():
            group = 'gemini'
        elif 'CLAUDE AND GPT' in line.upper():
            group = 'claude_gpt'
        elif group:
            m = re.search(r'(\d{1,3}\.\d{2})%', line)
            if m:
                used = round(100 - float(m.group(1)))
                ctx = ' '.join(lines[max(0,i-3):i+1]).lower()
                # The "Refreshes in ..." string is on a nearby line.
                reset = ""
                for j in range(i, min(i+3, len(lines))):
                    reset = parse_refresh(lines[j])
                    if reset:
                        break
                # "Quota available" (0% used) renders a full 100% bar with no
                # countdown — mark it with -1 so the UI shows a dash, not "0%".
                avail = any('quota available' in lines[j].lower()
                            for j in range(i, min(i + 3, len(lines))))
                window = 'weekly' if 'weekly' in ctx else ('5h' if 'five hour' in ctx else None)
                if window:
                    key = f'{group}_{window if window=="weekly" else "5h"}'
                    if key not in matched:
                        vals[key] = -1 if avail else used
                        resets[f'{key}_reset'] = '' if avail else reset
                        matched.add(key)
                        ok = True

# Accept only a complete-enough capture (both Gemini buckets + the C+G weekly
# bucket). C+G 5h often shows "Quota available" with no %, so it's optional.
# A partial capture (parallel runs occasionally render only part of the panel)
# must NOT overwrite good cached values with zeros / blank resets.
complete = {"gemini_weekly", "gemini_5h", "claude_gpt_weekly"}.issubset(matched)
if ok and complete:
    out = {**vals, **resets, "plan": g_plan, "gemini_ver": g_ver, "_fresh": True}
    print(json.dumps(out))
else:
    try:
        prev = json.load(open(os.path.expanduser("~/.ai_usage_cache.json"))).get("agy", {})
        print(json.dumps(prev))
    except Exception:
        print("{}")
PYEOF
)
  ;;

gemini)
  # Gemini API (Google AI Studio, paid project) — three sources, merged:
  #   1. Cloud Monitoring via the service account (Keychain aiusage.gcp.sa):
  #      raw DELTA points for output tokens / input tokens / requests per model,
  #      bucketed by calendar day. NOT the aligned-sum shortcut: a 30-day
  #      alignment bucket over-reached past interval.startTime and reported
  #      3.7-flash at 174k when the raw points summed to 31k.
  #   2. Cloud Billing Catalog (VND SKU prices, cached weekly) -> cost estimate.
  #      Cached input tokens have no metric, so they're priced at full rate:
  #      estimate runs ~10% high vs AI Studio.
  #   3. BigQuery billing export (exact daily cost incl. cache discounts) once
  #      Google has created the export table; queried at most every 6h.
  #   4. aistudio.google.com/billing scraped by the WebKit helper (Google login
  #      saved once): credit balance, last top-up, tier cap.
  # All three identifiers come from the Accounts window (config.json "gemini").
  GEMINI_PAID_PROJECT="$(cfg gemini.project)"
  GEMINI_BQ_TABLE="$(cfg gemini.bq_table)"
  GEMINI_BILLING_ACCOUNT="$(cfg gemini.billing_account)"
  GEMINI_CURRENCY="$(cfg gemini.currency VND)"
  RAW="$TMPDIR_USAGE/aistudio_raw.txt"
  # AI Studio opens the FIRST billing account by default; ?billing=&project=
  # selects the paid one. The balance card is a payments.google.com iframe,
  # which the helper appends after a ===FRAME=== marker.
  AISTUDIO_URL="https://aistudio.google.com/billing"
  if [ -n "$GEMINI_BILLING_ACCOUNT" ] && [ -n "$GEMINI_PAID_PROJECT" ]; then
    AISTUDIO_URL="$AISTUDIO_URL?billing=$GEMINI_BILLING_ACCOUNT&project=$GEMINI_PAID_PROJECT"
  fi
  HELPER_RC=0
  if [ -x "$HELPER" ]; then
    AIUSAGE_URL="$AISTUDIO_URL" "$HELPER" fetch-aistudio > "$RAW" 2>/dev/null
    HELPER_RC=$?
  fi

  FRAGMENT=$(GEMINI_PAID_PROJECT="$GEMINI_PAID_PROJECT" GEMINI_BQ_TABLE="$GEMINI_BQ_TABLE" GEMINI_CURRENCY="$GEMINI_CURRENCY" \
             AISTUDIO_RAW="$RAW" AISTUDIO_RC="$HELPER_RC" python3 2>> /tmp/ai_usage_err.log << 'PYEOF'
import json, os, re, sys, time, base64, subprocess, tempfile, urllib.request, urllib.parse
from datetime import datetime, timezone, timedelta

PAID = os.environ.get("GEMINI_PAID_PROJECT", ""); BQ_TABLE = os.environ.get("GEMINI_BQ_TABLE", "")
TZNAME = os.environ.get("TZNAME") or "UTC"
VN = datetime.now().astimezone().tzinfo; now = datetime.now(timezone.utc)   # day buckets follow the Mac's zone
# Money is kept in the billing account's currency. Zero-decimal currencies are
# whole numbers; the others keep cents.
CUR = (os.environ.get("GEMINI_CURRENCY") or "VND").upper()
DEC = 0 if CUR in ("VND", "JPY", "KRW", "IDR", "CLP", "ISK", "HUF", "TWD") else 2
def rnd(x): return round(x) if DEC == 0 else round(x, 2)
CACHE = os.path.expanduser("~/.ai_usage_cache.json")
PRICES = os.path.expanduser("~/.ai_usage_gemini_prices.json")
def prev():
    try: return json.load(open(CACHE)).get("gemini", {})
    except Exception: return {}
prev_g = prev()
out = dict(prev_g)          # start from last known; overwrite whatever we can refresh
out.pop("_fresh", None)

# ---------- 4. AI Studio billing page (balance / top-up / tier) ----------
text = ""
raw = os.environ.get("AISTUDIO_RAW", "")
if raw and os.path.exists(raw): text = open(raw, encoding="utf-8", errors="replace").read()
low = text.lower()
def vnd(s):   # an amount as printed by AI Studio in the account currency
    if DEC == 0: return int(re.sub(r"[^\d]", "", s))
    return float(re.sub(r"[^\d.]", "", s.replace(",", "")))
SYM = r"[^\d\s]{1,4}"   # currency symbol or code in front of the number
out["needs_login_google"] = os.environ.get("AISTUDIO_RC") == "3" or ("credit balance" not in low and bool(text) and "sign in" in low)
if "credit balance" in low:
    m = re.search(r"credit balance\s*\n\s*" + SYM + r"\s*([\d,\.]+)", text, re.I)
    if m: out["balance"] = vnd(m.group(1))
    m = re.search(SYM + r"\s*([\d,\.]+)\s+added on\s+([A-Za-z]{3,9}\s+\d{1,2})", text)
    if m: out["last_topup"] = {"amount": vnd(m.group(1)), "date": m.group(2)}
    m = re.search(r"(Paid \d+)\s*·\s*" + SYM + r"\s*([\d,\.]+)\s+Billing Account Tier Cap", text)
    if m: out["tier"] = m.group(1); out["tier_cap"] = vnd(m.group(2))
    out["balance_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
# AI Studio's own month-to-date total ("Total cost\n₫18.9K") — Google's number,
# includes cache discounts; shown next to our estimate as the reference.
m = re.search(r"Total cost\s*\n\s*" + SYM + r"\s*([\d\.,]+)\s*([KkMm]?)", text)
if m:
    v = float(m.group(1).replace(",", "")); v *= {"k": 1e3, "m": 1e6}.get(m.group(2).lower(), 1)
    out["spend_aistudio_month"] = rnd(v)
out["currency"] = CUR
if "tier cap" in low and "credit balance" not in low:
    # page reached but the payments iframe didn't render — keep old balance, note it
    out["balance_stale"] = True
elif "credit balance" in low:
    out.pop("balance_stale", None)

# ---------- Service-account token (RS256 JWT via openssl; no SDK needed) ----------
def sa_token():
    b = subprocess.run(["security", "find-generic-password", "-a", "aiusage", "-s", "aiusage.gcp.sa", "-w"],
                       capture_output=True, text=True).stdout.strip()
    sa = json.loads(base64.b64decode(b))
    b64 = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=").decode()
    t = int(time.time())
    hdr = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    clm = b64(json.dumps({"iss": sa["client_email"], "scope": "https://www.googleapis.com/auth/cloud-platform",
                          "aud": sa["token_uri"], "iat": t, "exp": t + 600}).encode())
    k = tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False); k.write(sa["private_key"]); k.close()
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", k.name], input=f"{hdr}.{clm}".encode(), capture_output=True).stdout
    os.unlink(k.name)
    r = urllib.request.urlopen(urllib.request.Request(sa["token_uri"], data=urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": f"{hdr}.{clm}.{b64(sig)}"}).encode()), timeout=20)
    return json.load(r)["access_token"]
if not PAID:
    # No paid project configured: only the AI Studio page is read. Fresh if it rendered.
    if "credit balance" in low: out["_fresh"] = True
    print(json.dumps(out)); sys.exit(0)
try:
    TOK = sa_token()
except Exception as e:
    print(json.dumps(out)); sys.exit(0)        # keep previous numbers, no _fresh
H = {"Authorization": "Bearer " + TOK, "x-goog-user-project": PAID, "Content-Type": "application/json"}
def call(url, body=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=H)
    return json.load(urllib.request.urlopen(req, timeout=40))

# ---------- 1. Monitoring: raw points -> per model per VN calendar day ----------
def raw_points(metric):
    q = {"filter": f'metric.type="{metric}"', "pageSize": "100000",
         "interval.startTime": (now - timedelta(days=32)).strftime("%Y-%m-%dT%H:%M:%SZ"),
         "interval.endTime": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    r = call(f"https://monitoring.googleapis.com/v3/projects/{PAID}/timeSeries?{urllib.parse.urlencode(q)}")
    per = {}   # model -> {day: value}
    for s in r.get("timeSeries", []):
        m = s["metric"]["labels"].get("model", "?")
        for p in s["points"]:
            v = p["value"]; val = int(v.get("int64Value") or 0) + float(v.get("doubleValue") or 0)
            day = datetime.fromisoformat(p["interval"]["endTime"].replace("Z", "+00:00")).astimezone(VN).strftime("%Y-%m-%d")
            per.setdefault(m, {})[day] = per.setdefault(m, {}).get(day, 0) + val
    return per
outp = raw_points("generativelanguage.googleapis.com/generate_content_usage_output_token_count")
inp  = raw_points("generativelanguage.googleapis.com/quota/generate_content_paid_tier_input_token_count/usage")
reqs = raw_points("generativelanguage.googleapis.com/quota/generate_requests_per_model/usage")

# ---------- 2. Prices (account currency per token), cached for 7 days ----------
def load_prices():
    try:
        c = json.load(open(PRICES))
        if time.time() - c.get("fetched_at", 0) < 7 * 86400 and c.get("currency", "VND") == CUR: return c["prices"]
    except Exception: pass
    skus, tok = [], ""
    while True:
        d = json.load(urllib.request.urlopen(urllib.request.Request(
            "https://cloudbilling.googleapis.com/v1/services/AEFD-7695-64FA/skus?currencyCode={CUR}&pageSize=5000" + (f"&pageToken={tok}" if tok else ""),
            headers={"Authorization": "Bearer " + TOK}), timeout=40))
        skus += d.get("skus", []); tok = d.get("nextPageToken", "")
        if not tok: break
    BAD = ("batch", "flex", "priority", "cach", "storage", "audio", "image", "video", "tts", "embed", "live", "bidi", "grounding", "search", "thinking")
    prices = {}
    for k in skus:
        d = k["description"].lower()
        if any(b in d for b in BAD) or "text" not in d or "token" not in d: continue
        kind = "in" if "input" in d else ("out" if "output" in d else None)
        if not kind: continue
        t = k["pricingInfo"][0]["pricingExpression"]["tieredRates"][0]["unitPrice"]
        price = int(t.get("units", "0")) + int(t.get("nanos", 0)) / 1e9
        prices.setdefault(d, {})[kind] = price
    json.dump({"fetched_at": time.time(), "currency": CUR, "prices": prices}, open(PRICES, "w"))
    return prices
try: sku_prices = load_prices()
except Exception: sku_prices = {}
def price_for(model):
    parts = model.replace("gemini-", "").split("-")
    want_lite, want_pro = "lite" in parts, "pro" in parts
    res = {}
    for d, pr in sku_prices.items():
        if not all(p in d for p in parts): continue
        if ("lite" in d) != want_lite or ("pro" in d) != want_pro: continue
        for kind, v in pr.items(): res.setdefault(kind, v)
    return res

# ---------- Aggregate: today / 7d / month (VN calendar) ----------
today = now.astimezone(VN).strftime("%Y-%m-%d")
week = {(now.astimezone(VN) - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7)}
month_prefix = today[:7]
models = sorted(set(outp) | set(inp) | set(reqs))
def agg(model, days):
    p = price_for(model)
    i = sum(v for d, v in inp.get(model, {}).items() if d in days)
    o = sum(v for d, v in outp.get(model, {}).items() if d in days)
    r = sum(v for d, v in reqs.get(model, {}).items() if d in days)
    return i, o, r, i * p.get("in", 0) + o * p.get("out", 0), bool(p)
month_days = {d for m in models for d in list(inp.get(m, {})) + list(outp.get(m, {})) if d.startswith(month_prefix)}
rows = []
for m in models:
    i, o, r, c, priced = agg(m, month_days)
    rows.append({"model": m, "in": int(i), "out": int(o), "requests": int(r), "cost": rnd(c), "priced": priced})
rows.sort(key=lambda x: -x["cost"])
def total(days): return rnd(sum(agg(m, days)[3] for m in models))
out["models"] = rows
out["spend_est"] = {"today": total({today}), "week": total(week), "month": total(month_days)}
alld = {}
for m in models:
    for d, v in outp.get(m, {}).items(): alld[d] = alld.get(d, 0) + agg(m, {d})[3]
out["daily_est"] = [{"d": d, "cost": rnd(alld.get(d, 0))} for d in sorted({(now.astimezone(VN) - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(30)})]

# ---------- 3. BigQuery exact cost (when the export table exists), every 6h ----------
last = prev_g.get("exact_at", "")
try: due = (now - datetime.fromisoformat(last.replace("Z", "+00:00"))).total_seconds() > 6 * 3600 if last else True
except Exception: due = True
if due and BQ_TABLE.count(".") == 2:
    try:
        proj, ds, tbl = BQ_TABLE.split(".")
        call(f"https://bigquery.googleapis.com/bigquery/v2/projects/{proj}/datasets/{ds}/tables/{tbl}")  # 404 -> not yet
        # project.id filter: the export also carries billing-account rows with
        # no project — the prepaid top-up shows up as "Invoice" (Billing
        # Adjustment + Tax, ₫200k on 2026-09-01) and would count as spend.
        sql = f"""SELECT FORMAT_DATE('%Y-%m-%d', DATE(usage_start_time, '{TZNAME}')) d,
                        SUM(cost) + SUM((SELECT IFNULL(SUM(c.amount), 0) FROM UNNEST(credits) c)) net
                 FROM `{BQ_TABLE}`
                 WHERE project.id = '{PAID}'
                   AND usage_start_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE('{TZNAME}'), INTERVAL 35 DAY), '{TZNAME}')
                 GROUP BY d ORDER BY d"""
        r = call(f"https://bigquery.googleapis.com/bigquery/v2/projects/{proj}/queries", {"query": sql, "useLegacySql": False, "timeoutMs": 30000})
        exact = {row["f"][0]["v"]: rnd(float(row["f"][1]["v"])) for row in r.get("rows", [])}
        out["daily_exact"] = exact
        out["exact_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    except urllib.error.HTTPError as e:
        if e.code == 404: out["exact_at"] = now.strftime("%Y-%m-%dT%H:%M:%SZ"); out.pop("daily_exact", None); out.pop("spend_exact", None)
        else: raise
# Hybrid totals, recomputed EVERY run (the query itself runs every 6h, but the
# estimate for today keeps moving): the export lags — it had backfilled only to
# 16/9 when today was 29/9 — so days after the last exported day take the
# Monitoring estimate instead of reading ₫0 because Google hasn't written them.
if isinstance(out.get("daily_exact"), dict):
    exact = out["daily_exact"]; through = max(exact) if exact else None
    best = lambda d: exact.get(d, 0) if through and d <= through else rnd(alld.get(d, 0))
    recent = [(now.astimezone(VN) - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(31)]
    out["spend_exact"] = {"today": best(today), "week": rnd(sum(best(d) for d in week)),
                          "month": rnd(sum(best(d) for d in recent if d.startswith(month_prefix)))}
    out["exact_through"] = through
# 30-day daily series for the app's chart, same hybrid rule as the totals.
days = sorted((now.astimezone(VN) - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(30))
ex = out.get("daily_exact") if isinstance(out.get("daily_exact"), dict) else {}
thr = max(ex) if ex else None
out["daily"] = [{"d": d, "cost": (ex.get(d, 0) if thr and d <= thr else rnd(alld.get(d, 0)))} for d in days]
out["project"] = PAID
out["_fresh"] = True
print(json.dumps(out))
PYEOF
)
  ;;

insights)
  # Local-only analytics (no network): what is eating the Claude limits, from
  # Claude Code's own session transcripts under ~/.claude/projects, plus Codex
  # CLI rollouts under ~/.codex/sessions. Same idea as the "What's contributing
  # to your limits usage?" panel in Claude Code for VS Code. Approximate: only
  # sessions on this machine + the remote hosts below, not claude.ai chats.
  #
  # Remote hosts: Claude Code run over SSH / VS Code Remote (the "Remote"
  # sessions on claude.ai/code) keeps its transcripts on THAT machine. Each host
  # runs remote_insights.py (sent over the SSH session itself, so nothing has to
  # be installed there; incremental via its own state file, ~0.5s) and streams back the last 7 days of requests as gzip JSON; on failure the last
  # good copy in ~/.ai_usage_remote_<host>.json is reused so the card degrades
  # to slightly old numbers instead of dropping the host.
  # Hosts come from the Accounts window: name, host, user, port and key per host
  # (plain strings from older configs are just a host). Key-based SSH only.
  # Fields are split on \x1f, not tab: bash merges runs of tabs, so an empty
  # user field shifted the key path into the port ("Bad port '~/.ssh/...'").
  REMOTE_SPEC=""
  while IFS=$'\x1f' read -r r_name r_host r_user r_port r_key; do
    [ -z "$r_host" ] && continue
    target="$r_host"; [ -n "$r_user" ] && target="$r_user@$r_host"
    opts=(-o BatchMode=yes -o ConnectTimeout=8)
    [ -n "$r_port" ] && [ "$r_port" != "22" ] && opts+=(-p "$r_port")
    [ -n "$r_key" ] && opts+=(-i "${r_key/#\~/$HOME}" -o IdentitiesOnly=yes)
    keep="$HOME/.ai_usage_remote_$r_host.json"
    if ssh "${opts[@]}" "$target" \
         'python3 - | gzip -c' 2>> /tmp/ai_usage_err.log < "$SELF_DIR/remote_insights.py" \
       | gzip -dc > "$TMPDIR_USAGE/remote_$r_host.json" 2>/dev/null && [ -s "$TMPDIR_USAGE/remote_$r_host.json" ]; then
      cp "$TMPDIR_USAGE/remote_$r_host.json" "$keep"
    else
      echo "$(date '+%F %T') insights: remote $r_host unreachable, using cached copy" >> /tmp/ai_usage_err.log
    fi
    [ -s "$keep" ] && REMOTE_SPEC="$REMOTE_SPEC$keep"$'\t'"$r_name"$'\t'"$r_host"$'\n'
  done < <(python3 -c '
import json, sys
try: hosts = json.load(open(sys.argv[1])).get("remote_hosts") or []
except Exception: hosts = []
for h in hosts:
    if isinstance(h, str): h = {"host": h}
    print("\x1f".join(str(h.get(k) or "") for k in ("name", "host", "user", "port", "key")))
' "$AIU_CONFIG")
  FRAGMENT=$(REMOTE_SPEC="$REMOTE_SPEC" AIU_BIN="$SELF_DIR" python3 2>> /tmp/ai_usage_err.log << 'PYEOF'
import json, os, re, glob, collections, sys, time, subprocess
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc)
VN = datetime.now().astimezone().tzinfo   # the Mac's zone
def ts(s):
    try: return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception: return None
# "Limit weight" of one request ~ API price ratios: input 1, cache write 1.25,
# cache read 0.1, output 5. Percentages below are shares of this weight.
def weight(u):
    return (u.get("input_tokens", 0) + 1.25 * u.get("cache_creation_input_tokens", 0)
            + 0.1 * u.get("cache_read_input_tokens", 0) + 5 * u.get("output_tokens", 0))

root = os.path.expanduser("~/.claude/projects")
# Cowork (Claude desktop "local agent mode") does NOT write to ~/.claude/projects:
# each session keeps an SDK stream-json transcript at
#   ~/Library/Application Support/Claude/local-agent-mode-sessions/<org>/<user>/local_<id>/audit.jsonl
# (same assistant/message/usage shape; timestamp is `_audit_timestamp`, session
# is `session_id`, subagent turns carry `subagent_type`). Title from local_<id>.json.
cowork = os.path.expanduser("~/Library/Application Support/Claude/local-agent-mode-sessions")
since7 = now - timedelta(days=7)
reqs = []                                   # (sid, project, model, ctx, w, t, subagent_type)
span = collections.defaultdict(lambda: [None, None])
sources = [(f, None) for f in glob.glob(f"{root}/*/*.jsonl") + glob.glob(f"{root}/*/*/subagents/*.jsonl")]
sources += [(f, "cowork") for f in glob.glob(f"{cowork}/*/*/local_*/audit.jsonl")]
for f, kind in sources:
    try:
        if datetime.fromtimestamp(os.path.getmtime(f), timezone.utc) < since7: continue
    except Exception: continue
    if kind == "cowork":
        try: title = json.load(open(os.path.dirname(f) + ".json")).get("title") or "phiên"
        except Exception: title = "phiên"
        project = "Cowork · " + title
    else:
        project = f[len(root)+1:].split("/")[0]
        # Claude Code names the folder after the project path with "/" -> "-";
        # drop this user's home prefix so "-Users-me-Code-app" reads "Code app".
        home_enc = os.path.expanduser("~").replace("/", "-")
        if project.startswith(home_enc + "-"): project = project[len(home_enc) + 1:]
        elif project == home_enc: project = "home"
        project = project.replace("-", " ").strip()
    sub = None
    if "/subagents/" in f:
        try: sub = json.load(open(f[:-6] + ".meta.json")).get("agentType", "other")
        except Exception: sub = "other"
    seen = set()
    try:
        for line in open(f, errors="replace"):
            try: o = json.loads(line)
            except Exception: continue
            t = ts(o.get("timestamp") or o.get("_audit_timestamp") or ""); sid = o.get("sessionId") or o.get("session_id")
            if not t or not sid: continue
            sp = span[sid]; sp[0] = min(sp[0] or t, t); sp[1] = max(sp[1] or t, t)
            m = o.get("message")
            if o.get("type") != "assistant" or not isinstance(m, dict) or t < since7: continue
            rid = o.get("requestId") or m.get("id")
            if rid in seen: continue            # one request spans several lines
            seen.add(rid)
            u = m.get("usage") or {}
            ctx = u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0)
            reqs.append((sid, project, m.get("model", "?"), ctx, weight(u), t, sub or o.get("subagent_type")))
    except Exception: continue

# ---- remote hosts (see the shell part): same tuple shape, project labelled by host
remote_status = []; remote_blobs = []
for spec in os.environ.get("REMOTE_SPEC", "").splitlines():
    rf, name, target = (spec.split("\t") + ["", ""])[:3]
    try:
        d = json.load(open(rf)); host = name or d.get("host") or target
        for sid, dirname, model, t0, i, cc, cr, o, sub in d.get("reqs", []):
            t = ts(t0)
            if not t or t < since7: continue
            name = re.sub(r"^-(home|Users)-[^-]+-?", "", dirname).replace("-", " ").strip() or "home"
            u = {"input_tokens": i, "cache_creation_input_tokens": cc, "cache_read_input_tokens": cr, "output_tokens": o}
            reqs.append((host + ":" + sid, f"{host} · {name}", model, i + cc + cr, weight(u), t, sub))
        for sid, (a, b) in d.get("span", {}).items():
            ta, tb = ts(a), ts(b)
            if ta and tb: span[host + ":" + sid] = [ta, tb]
        remote_status.append({"host": host, "target": target, "at": d.get("at"), "ok": os.path.getmtime(rf) > time.time() - 900})
        remote_blobs.append((host, d))
    except Exception as e:
        print("remote insights", rf, e, file=sys.stderr)

def analyse(hours):
    since = now - timedelta(hours=hours)
    rs = [r for r in reqs if r[5] >= since]
    W = sum(r[4] for r in rs)
    if W <= 0: return {"requests": 0, "sessions": 0}
    pct = lambda x: round(100 * x / W)
    sess_all, sess_sub, sub_w = collections.Counter(), collections.Counter(), collections.Counter()
    for r in rs:
        sess_all[r[0]] += r[4]
        if r[6]: sub_w[r[6]] += r[4]; sess_sub[r[0]] += r[4]
    heavy = {s for s in sess_all if sess_all[s] > 0 and sess_sub[s] / sess_all[s] >= 0.3}   # zero-weight sessions exist
    long_s = {s for s, (a, b) in span.items() if a and b and (b - a) >= timedelta(hours=8)}
    by = lambda key: sorted(((k, pct(v)) for k, v in collections.Counter({}).items()), key=lambda x: -x[1])
    def top(idx, n=4):
        c = collections.Counter()
        for r in rs: c[r[idx]] += r[4]
        return [{"name": k, "pct": pct(v)} for k, v in c.most_common(n)]
    return {
        "requests": len(rs), "sessions": len(sess_all),
        "subagent_heavy_pct": pct(sum(r[4] for r in rs if r[0] in heavy)),
        "long_session_pct": pct(sum(r[4] for r in rs if r[0] in long_s)),
        "big_context_pct": pct(sum(r[4] for r in rs if r[3] > 150_000)),
        "subagents": [{"name": k, "pct": pct(v)} for k, v in sub_w.most_common(3)],
        "models": top(2), "projects": top(1),
    }
out = {"day": analyse(24), "week": analyse(24 * 7)}
# hourly weight share, last 24h, VN local hours (oldest first)
hours = collections.Counter()
for r in reqs:
    if r[5] >= now - timedelta(hours=24):
        hours[r[5].astimezone(VN).replace(minute=0, second=0, microsecond=0)] += r[4]
W24 = sum(hours.values()) or 1
start = (now - timedelta(hours=23)).astimezone(VN).replace(minute=0, second=0, microsecond=0)
out["hourly"] = [{"h": (start + timedelta(hours=i)).strftime("%H"), "pct": round(100 * hours[start + timedelta(hours=i)] / W24, 1)} for i in range(24)]

# ---- Codex CLI: this Mac via the shared analyser (ai_usage_remote_insights.py
# --codex-only — the very file the SSH hosts run), plus each remote host's
# "codex" block. Raw counts are summed here and only then turned into shares.
def load_codex_blocks():
    blocks = []
    try:
        r = subprocess.run(["python3", os.path.join(os.environ.get("AIU_BIN", ""), "remote_insights.py"), "--codex-only"],
                           capture_output=True, text=True, timeout=90)
        blocks.append(("máy này", json.loads(r.stdout).get("codex")))
    except Exception as e: print("local codex", e, file=sys.stderr)
    for host, d in remote_blobs: blocks.append((host, d.get("codex")))
    return blocks
codex_blocks = load_codex_blocks()
SOURCE_LABEL = {"exec": "codex exec (review)", "vscode": "VS Code", "cli": "Terminal"}
def codex_merge(rng):
    tot = {"sessions": 0, "turns": 0, "responses": 0, "tokens": 0, "peak_context_pct": 0, "compactions": 0, "open": 0, "last_activity": None,
           "dur_ms": 0, "by_host": []}
    tok, models, hourly, sources, projects, status, items = ({} for _ in range(7))
    def add(d, src):
        for k, v in (src or {}).items(): d[k] = d.get(k, 0) + v
    for host, blk in codex_blocks:
        r = (blk or {}).get(rng)
        if not r: continue
        for k in ("sessions", "turns", "responses", "tokens", "compactions", "open", "dur_ms"): tot[k] += r.get(k, 0)
        tot["peak_context_pct"] = max(tot["peak_context_pct"], r.get("peak_context_pct", 0))
        if r.get("last_activity") and (not tot["last_activity"] or r["last_activity"] > tot["last_activity"]): tot["last_activity"] = r["last_activity"]
        add(tok, r.get("tok")); add(models, r.get("models")); add(hourly, r.get("hourly")); add(sources, r.get("sources"))
        add(projects, r.get("projects")); add(status, r.get("status")); add(items, r.get("items"))
        tot["by_host"].append({"host": host, "turns": r.get("turns", 0)})
    T = tot["tokens"] or 1; N = tot["turns"] or 1
    share = lambda d, base, n=4: [{"name": k, "pct": round(100 * v / base)} for k, v in sorted(d.items(), key=lambda x: -x[1])[:n]]
    tot["tok"] = tok
    tot["models"] = share(models, T, 3)
    tot["sources"] = [{"name": SOURCE_LABEL.get(x["name"], x["name"]), "pct": x["pct"]} for x in share(sources, N)]
    tot["projects"] = share(projects, N, 3)
    tot["status"] = status; tot["items"] = items
    tot["avg_turn_s"] = round(tot["dur_ms"] / 1000 / N) if tot["turns"] else 0
    tot["_hourly"] = hourly
    return tot
out["codex"] = {"day": codex_merge("day"), "week": codex_merge("week")}
# 24 hourly slots (VN), oldest first, share of the last-24h token total — same shape as the Claude chart
h = out["codex"]["day"].pop("_hourly"); out["codex"]["week"].pop("_hourly", None)
HT = sum(h.values()) or 1
start = (now - timedelta(hours=23)).astimezone(VN).replace(minute=0, second=0, microsecond=0)
out["codex"]["hourly"] = [{"h": (start + timedelta(hours=i)).strftime("%H"),
                           "pct": round(100 * h.get((start + timedelta(hours=i)).strftime("%Y-%m-%d %H"), 0) / HT, 1)} for i in range(24)]
out["codex"]["any"] = bool(glob.glob(os.path.expanduser("~/.codex/*.sqlite")) or glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/*.jsonl"))
                           or out["codex"]["week"]["turns"] > 0)
out["remote"] = remote_status
out["_fresh"] = True
print(json.dumps(out))
PYEOF
)
  ;;

codexhist)
  # Server-side Codex analytics — the same endpoints the Codex tab of the
  # ChatGPT macOS app uses for Settings → Usage → Analytics (found in its
  # app.asar): every 5h / weekly limit window of the last 7 days with its %
  # used and a per-model / per-surface split, plus usage per day per model.
  # Covers ALL devices and surfaces (Codex app, CLI, exec reviews, remote hosts),
  # unlike the local rollout parsing in `insights`.
  FRAGMENT=$(python3 2>> /tmp/ai_usage_err.log << 'PYEOF'
import json, os, urllib.request, urllib.error
from datetime import datetime, timezone, timedelta
a = json.load(open(os.path.expanduser("~/.codex/auth.json")))
t = a.get("tokens") or {}
H = {"Authorization": "Bearer " + t.get("access_token", ""), "Accept": "application/json", "User-Agent": "codex_cli_rs"}
if t.get("account_id"): H["ChatGPT-Account-Id"] = t["account_id"]
def get(path):
    return json.load(urllib.request.urlopen(urllib.request.Request("https://chatgpt.com/backend-api" + path, headers=H), timeout=20))
out = {}
pct = lambda bp: round((bp or 0) / 100, 1)
plan = get("/wham/usage/plan_limit_history?days=7")
periods = []
for p in plan.get("periods") or []:
    br = {b["dimension"]: sorted(((r["key"], pct(r["basis_points"])) for r in b.get("rows") or []), key=lambda x: -x[1])
          for b in p.get("breakdowns") or []}
    periods.append({"w": p["window_minutes"], "start": p["starts_at"], "end": p["ends_at"], "pct": pct(p.get("used_basis_points")),
                    "done": p.get("accounting_complete", False),
                    "models": br.get("model", [])[:4], "surfaces": br.get("surface", [])[:4], "sources": br.get("thread_source", [])[:4]})
periods.sort(key=lambda p: p["start"], reverse=True)
out["periods"] = periods
out["data_as_of"] = plan.get("data_as_of")
end = datetime.now(timezone.utc).date(); start = end - timedelta(days=6)
daily = get(f"/wham/usage/daily-token-usage-breakdown?start_date={start}&end_date={end}&group_by=day")
out["units"] = daily.get("units")
out["daily"] = [{"d": d["date"],
                 "models": {m["model"]: round(m.get("credits", 0), 2) for m in d.get("models") or [] if m.get("credits", 0) > 0},
                 "surfaces": {k: round(v, 2) for k, v in (d.get("product_surface_usage_values") or {}).items() if v > 0}}
                for d in daily.get("data") or []]
# Banked "rate limit reset" credits (Full reset = weekly + 5h): what is left, when
# it expires, and the grant/use history of the last 30 days. Best effort — the
# limit history above must still land if this endpoint errors.
try:
    rc = get("/wham/rate-limit-reset-credits")
    hist = get("/wham/rate-limit-reset-credits/history")
    ev = [{"kind": e["kind"], "at": e["occurred_at"]} for e in hist.get("events") or []]
    out["resets"] = {
        "available": rc.get("available_count", 0),
        "usable_now": 0,
        "credits": [{"id": c.get("id"), "title": c.get("title"), "granted": c.get("granted_at"), "expires": c.get("expires_at"), "status": c.get("status")}
                    for c in rc.get("credits") or []],
        "used_30d": sum(1 for e in ev if e["kind"] == "used"),
        "granted_30d": sum(1 for e in ev if e["kind"] == "granted"),
        "last_used": next((e["at"] for e in ev if e["kind"] == "used"), None),
        "history": ev[:6],
    }
    try:
        u = get("/wham/usage").get("rate_limit_reset_credits") or {}
        out["resets"]["usable_now"] = u.get("applicable_available_count", 0)
    except Exception: pass
except Exception as e:
    import sys; print("codexhist resets:", e, file=sys.stderr)
out["_fresh"] = True
print(json.dumps(out))
PYEOF
)
  ;;

*)
  echo "unknown provider: $PROVIDER" >&2; exit 1 ;;
esac

# Merge fragment into combined cache atomically (file-locked).
# updated_at only advances on a genuinely fresh capture (frag carries \"_fresh\") —
# a failed fetch that re-merges old numbers must NOT make the clock lie.
echo "$FRAGMENT" | python3 -c "
import json, sys, os, fcntl, time
provider = sys.argv[1]
try:
    frag = json.load(sys.stdin)
except Exception:
    frag = {}
if not frag:
    sys.exit(0)
fresh = bool(frag.pop('_fresh', False))
cache = os.path.expanduser('~/.ai_usage_cache.json')
lock = cache + '.lock'
with open(lock, 'w') as lf:
    fcntl.flock(lf, fcntl.LOCK_EX)
    try:
        data = json.load(open(cache))
    except Exception:
        data = {}
    now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    if fresh:
        # Per-provider freshness: the UI flags each card on its own, so one
        # broken provider can't hide behind the others' successful fetches.
        frag['fetched_at'] = now
        data['updated_at'] = now
    elif 'fetched_at' not in frag:
        # Non-fresh fragments (fallbacks) keep the last real fetch time.
        prev_at = (data.get(provider) or {}).get('fetched_at')
        if prev_at:
            frag['fetched_at'] = prev_at
    data[provider] = frag
    tmp = cache + '.tmp'
    json.dump(data, open(tmp, 'w'), indent=2)
    os.replace(tmp, cache)
    json.dump(data, open('/tmp/ai_usage_cache.json', 'w'), indent=2)
" "$PROVIDER" 2>> /tmp/ai_usage_err.log

# (Widget redraw is handled by the refresh intent's reloadAllTimelines and by the
# widget's own timeline policy — not by killing the extension, which is unreliable
# and would also kill the in-flight refresh intent.)

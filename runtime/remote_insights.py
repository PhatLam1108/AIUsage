#!/usr/bin/env python3
# Runs ON a remote host (over ssh) where Claude Code also writes ~/.claude/projects:
# emits the assistant requests of the last 7 days as compact JSON, so the Mac's
# `fetch_one.sh insights` can fold remote sessions into the same analysis.
#
# Incremental: transcripts are append-only, so per file we remember the byte
# offset already parsed (plus size/mtime) in ~/.cache/ai_usage_remote_state.json
# and only read what was appended since — 1.4 GB of rollouts costs ~nothing
# per run after the first pass.
#
# Output: {"host": ..., "reqs": [[sid, project, model, ts, in, cache_create, cache_read, out, subagent], ...],
#          "span": {sid: [first_ts, last_ts]}}
import json, os, glob, time, socket, sys
from datetime import datetime, timezone, timedelta

ROOT = os.path.expanduser("~/.claude/projects")
STATE = os.path.expanduser("~/.cache/ai_usage_remote_state.json")
now = datetime.now(timezone.utc)
since7 = now - timedelta(days=7)
try: state = json.load(open(STATE))
except Exception: state = {}

def ts(s):
    try: return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception: return None

# ---- Codex on this host (CLI / VS Code / `codex exec` reviews). Raw counts
# only — the Mac sums every host's block and turns them into percentages.
# Also run standalone with --codex-only: the Mac uses this same file for its
# own ~/.codex so the two hosts can never drift apart.
import sqlite3
VN = timezone(timedelta(hours=7))
def dbpath(prefix):
    c = sorted(glob.glob(os.path.expanduser(f"~/.codex/{prefix}_*.sqlite")))
    return c[-1] if c else None
def sql(db, q, args=()):
    if not db or not os.path.exists(db): return None
    try:
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True); r = c.execute(q, args).fetchall(); c.close(); return r
    except Exception: return None
def codex(hours):
    since = now - timedelta(hours=hours)
    z = {"sessions": 0, "turns": 0, "responses": 0, "tokens": 0, "peak_context_pct": 0, "compactions": 0, "open": 0,
         "last_activity": None, "tok": {"input": 0, "cached": 0, "output": 0, "reasoning": 0}, "models": {}, "hourly": {},
         "sources": {}, "projects": {}, "status": {}, "dur_ms": 0, "items": {}}
    peak = 0.0; last_ts = None
    for f in glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/*.jsonl")):
        try:
            if datetime.fromtimestamp(os.path.getmtime(f), timezone.utc) < since: continue
        except Exception: continue
        had = False; model = "?"
        try:
            for line in open(f, errors="replace"):
                try: o = json.loads(line)
                except Exception: continue
                t = ts(o.get("timestamp", ""))
                if not t: continue
                p = o.get("payload") or {}
                if o.get("type") == "turn_context":            # model in force for the turns that follow
                    model = p.get("model") or model; continue
                if p.get("type") == "token_count" and p.get("info"): last_ts = max(last_ts or t, t)
                if t < since: continue
                if o.get("type") == "compacted": z["compactions"] += 1
                if p.get("type") == "token_count" and p.get("info"):
                    lu = p["info"].get("last_token_usage") or {}; win = p["info"].get("model_context_window") or 0
                    tot = lu.get("total_tokens", 0); ci = lu.get("cached_input_tokens", 0); ro = lu.get("reasoning_output_tokens", 0)
                    z["tokens"] += tot; z["responses"] += 1; had = True
                    # OpenAI usage: cached ⊂ input, reasoning ⊂ output — split them out
                    z["tok"]["input"] += max(0, lu.get("input_tokens", 0) - ci); z["tok"]["cached"] += ci
                    z["tok"]["output"] += max(0, lu.get("output_tokens", 0) - ro); z["tok"]["reasoning"] += ro
                    z["models"][model] = z["models"].get(model, 0) + tot
                    if hours <= 24:
                        hk = t.astimezone(VN).strftime("%Y-%m-%d %H"); z["hourly"][hk] = z["hourly"].get(hk, 0) + tot
                    if win: peak = max(peak, lu.get("input_tokens", 0) / win)
        except Exception: continue
        z["sessions"] += had
    z["turns"] = z["responses"]; turned = set()
    hist, state = dbpath("thread_history"), dbpath("state")
    rows = sql(hist, "SELECT thread_id, COUNT(*), SUM(COALESCE(duration_ms, 0)) FROM thread_turns WHERE started_at >= ? GROUP BY 1",
               (int(since.timestamp()),))
    if rows is not None:
        z["turns"] = sum(r[1] for r in rows); turned = {r[0] for r in rows}
        z["sessions"] = max(z["sessions"], len(rows)); z["dur_ms"] = sum(r[2] or 0 for r in rows)
        z["status"] = {r[0]: r[1] for r in sql(hist, "SELECT status, COUNT(*) FROM thread_turns WHERE started_at >= ? GROUP BY 1",
                                                (int(since.timestamp()),)) or []}
        z["items"] = {r[0]: r[1] for r in sql(hist, "SELECT item_type, COUNT(*) FROM thread_items WHERE created_at_ms >= ? GROUP BY 1",
                                               (int(since.timestamp() * 1000),)) or []
                      if r[0] in ("commandExecution", "fileChange", "mcpToolCall", "webSearch")}
        last = sql(hist, "SELECT MAX(COALESCE(completed_at, started_at)) FROM thread_turns")
        if last and last[0][0]:
            t = datetime.fromtimestamp(last[0][0], timezone.utc); last_ts = max(last_ts or t, t)
        meta = {r[0]: (r[1] or "?", r[2] or "") for r in sql(state, "SELECT id, source, cwd FROM threads") or []}
        for tid, n, _ in rows:
            src, cwd = meta.get(tid, ("?", ""))
            z["sources"][src] = z["sources"].get(src, 0) + n
            proj = os.path.basename(cwd.rstrip("/")) or "~"
            z["projects"][proj] = z["projects"].get(proj, 0) + n
    for lk in glob.glob(os.path.expanduser("~/.codex/thread-writer-locks/*.lock")):
        tid = os.path.basename(lk)[:-5]
        try: touched = datetime.fromtimestamp(os.path.getmtime(lk), timezone.utc)
        except Exception: continue
        if tid.startswith(".") or tid in turned or touched < max(since, now - timedelta(hours=12)): continue
        z["open"] += 1
    z["peak_context_pct"] = round(100 * peak)
    z["last_activity"] = last_ts.strftime("%Y-%m-%dT%H:%M:%SZ") if last_ts else None
    return z
codex_out = {"day": codex(24), "week": codex(24 * 7)} if os.path.isdir(os.path.expanduser("~/.codex")) else None
if "--codex-only" in sys.argv:
    print(json.dumps({"host": socket.gethostname(), "codex": codex_out, "at": now.strftime("%Y-%m-%dT%H:%M:%SZ")})); sys.exit(0)

files = glob.glob(f"{ROOT}/*/*.jsonl") + glob.glob(f"{ROOT}/*/*/subagents/*.jsonl")
live = set()
for f in files:
    try: st = os.stat(f)
    except Exception: continue
    if datetime.fromtimestamp(st.st_mtime, timezone.utc) < since7: continue
    live.add(f)
    s = state.get(f) or {"off": 0, "reqs": [], "span": None, "sub": None, "seen": []}
    if s["off"] > st.st_size: s = {"off": 0, "reqs": [], "span": None, "sub": None, "seen": []}   # rewritten, reparse
    if s["off"] == st.st_size and s.get("done"): state[f] = s; continue
    if "/subagents/" in f and s["sub"] is None:
        try: s["sub"] = json.load(open(f[:-6] + ".meta.json")).get("agentType", "other")
        except Exception: s["sub"] = "other"
    project = f[len(ROOT)+1:].split("/")[0]
    seen = set(s["seen"][-500:])
    try:
        fh = open(f, "rb"); fh.seek(s["off"])
        while True:
            pos = fh.tell(); line = fh.readline()
            if not line: break
            if not line.endswith(b"\n"): fh.seek(pos); break            # partial line still being written
            try: o = json.loads(line)
            except Exception: continue
            t = o.get("timestamp"); sid = o.get("sessionId")
            if not t or not sid or not ts(t): continue
            sp = s["span"] or [t, t]; s["span"] = [min(sp[0], t), max(sp[1], t)]
            m = o.get("message")
            if o.get("type") != "assistant" or not isinstance(m, dict): continue
            rid = o.get("requestId") or m.get("id")
            if rid in seen: continue
            seen.add(rid); s["seen"] = (s["seen"] + [rid])[-500:]
            u = m.get("usage") or {}
            s["reqs"].append([sid, project, m.get("model", "?"), t, u.get("input_tokens", 0), u.get("cache_creation_input_tokens", 0),
                              u.get("cache_read_input_tokens", 0), u.get("output_tokens", 0), s["sub"]])
        s["off"] = fh.tell(); fh.close()
    except Exception: pass
    s["done"] = True
    state[f] = s

state = {f: s for f, s in state.items() if f in live}
try:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"; json.dump(state, open(tmp, "w")); os.replace(tmp, STATE)
except Exception: pass

cut = since7.strftime("%Y-%m-%dT%H:%M:%S")
reqs = [r for s in state.values() for r in s["reqs"] if r[3] >= cut]
span = {}
for s in state.values():
    if s["span"]:
        for r in s["reqs"]:
            sid = r[0]; a, b = s["span"]
            sp = span.get(sid) or [a, b]; span[sid] = [min(sp[0], a), max(sp[1], b)]
print(json.dumps({"host": socket.gethostname(), "reqs": reqs, "span": span, "codex": codex_out, "at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}))

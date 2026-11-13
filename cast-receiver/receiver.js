/* AIUsage Cast receiver.
 *
 * The AIUsage Mac app launches this page on a Cast display and sends one JSON snapshot on the
 * namespace below whenever its numbers change. The page only renders: countdowns, the clock and
 * the pace readings are computed here from absolute timestamps, so the screen stays right between
 * snapshots and keeps the last numbers (marked as old) if the Mac goes to sleep. Nothing is stored
 * on the device.
 *
 * Open the page in a normal browser (or add ?demo) to see it with sample data;
 * ?snapshot=<url> loads a snapshot the Mac app saved (cast-snapshot.json) instead.
 */
(function () {
  "use strict";

  var NS = "urn:x-cast:net.phatdev.aiusage";
  var STORE_KEY = "aiusage.snapshot";      // used by early builds; cleared on start
  var OLD_AFTER_MS = 20 * 60 * 1000;   // no snapshot for 20 min: the Mac is probably asleep
  var STALE_FETCH_MS = 90 * 60 * 1000; // same rule as the app: a source not fetched for 90 min is old
  var WEEK = 7 * 86400, FIVE_HOURS = 5 * 3600;

  var params = new URLSearchParams(location.search);
  var demo = params.has("demo") || !/CrKey/.test(navigator.userAgent) || !(window.cast && cast.framework);

  // Wording follows the Mac app's String Catalog.
  var T = {
    vi: {
      justReset: "Vừa reset", updated: "Cập nhật lúc", macAway: "Mac ngắt kết nối từ",
      waiting: "Đang chờ số liệu từ máy Mac", needsLogin: "Cần đăng nhập lại", loginHint: "Mở AIUsage trên Mac để đăng nhập",
      notConnected: "Chưa kết nối", fiveHours: "5 giờ", week: "Tuần",
      limits: "Hạn mức", resets: "Lượt reset", forecast: "Dự báo", expires: "hết hạn", spent: "Đã chi", last24h: "24 giờ", left: "Còn lại",
      ahead: "Nhanh hơn nhịp {n} điểm", behind: "Chậm hơn nhịp {n} điểm", even: "Đúng nhịp đều",
      aheadShort: "Nhanh {n} điểm", behindShort: "Chậm {n} điểm", evenShort: "Đúng nhịp",
      room: "Còn dùng được {r}", roomShort: "còn {r}", perDay: "%/ngày", perHour: "%/giờ"
    },
    en: {
      justReset: "Just reset", updated: "Updated", macAway: "Mac disconnected since",
      waiting: "Waiting for numbers from your Mac", needsLogin: "Sign in again", loginHint: "Open AIUsage on your Mac to sign in",
      notConnected: "Not connected", fiveHours: "5 hours", week: "Week",
      limits: "Limits", resets: "Resets", forecast: "Forecast", expires: "expires", spent: "Spent", last24h: "24 hours", left: "Left",
      ahead: "{n} points ahead of pace", behind: "{n} points behind pace", even: "On the even pace",
      aheadShort: "{n} pts ahead", behindShort: "{n} pts behind", evenShort: "On pace",
      room: "Room for {r}", roomShort: "{r} left", perDay: "%/day", perHour: "%/hour"
    }
  };

  var snap = null;          // last snapshot
  var receivedAt = 0;       // when it arrived (ms)
  var lang = (params.get("lang") || navigator.language || "vi").slice(0, 2) === "en" ? "en" : "vi";

  function t(k, vars) {
    var s = (T[lang] || T.vi)[k] || "";
    if (vars) for (var key in vars) s = s.replace("{" + key + "}", vars[key]);
    return s;
  }
  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function hhmm(ms) { var d = new Date(ms); return pad(d.getHours()) + ":" + pad(d.getMinutes()); }
  function brandOf(b) { return b === "claude" || b === "openai" ? b : "gemini"; }

  // ---------- Layout: fit the 900x527 stage to whatever screen this is ----------
  var STAGE_W = 900, STAGE_H = 527;
  function fit() {
    var s = Math.min(window.innerWidth / STAGE_W, window.innerHeight / STAGE_H);
    $("stage").style.transform = "translate(-50%, -50%) scale(" + s + ")";
  }
  window.addEventListener("resize", fit);

  // ---------- Quota maths (same as the app's quotaRead) ----------
  function countdown(resetMs, now) {
    var secs = Math.max(0, Math.floor((resetMs - now) / 1000));
    var d = Math.floor(secs / 86400), h = Math.floor((secs % 86400) / 3600), m = Math.floor((secs % 3600) / 60);
    if (d > 0) return d + "d " + h + "h";
    if (h > 0) return h + "h " + m + "m";
    return m + ":" + pad(secs % 60);        // last hour: per-second countdown
  }
  function countdownText(b, now) {
    if (!b || !b.reset) return "";
    return b.reset <= now ? t("justReset") : countdown(b.reset, now);
  }
  function paceFraction(b, now) {
    if (!b.reset || !b.window || b.reset <= now) return null;
    var remaining = (b.reset - now) / 1000;
    if (remaining > b.window * 1.05) return null;
    return Math.min(1, Math.max(0, 1 - remaining / b.window));
  }
  function quotaRead(b, now) {
    if (!b || b.value < 0 || !b.window) return null;
    var frac = paceFraction(b, now);
    if (frac == null) return null;
    var hours = (b.reset - now) / 3600000;
    var left = Math.max(0, 100 - b.value);
    var safe = null;
    if (hours > 0 && b.value < 100) {
      if (hours >= 24) safe = Math.round(left / (hours / 24)) + t("perDay");
      else safe = (left / hours >= 10 ? Math.round(left / hours) : (left / hours).toFixed(1)) + t("perHour");
    }
    return { frac: frac, delta: b.value - Math.round(frac * 100), safe: safe };
  }
  function paceWords(read, short) {
    if (!read) return { text: "", fast: false };
    var d = read.delta;
    if (d > 5) return { text: t(short ? "aheadShort" : "ahead", { n: d }), fast: true };
    if (d < -5) return { text: t(short ? "behindShort" : "behind", { n: -d }), fast: false };
    return { text: t(short ? "evenShort" : "even"), fast: false };
  }
  function sev(v) { return v >= 85 ? "crit" : v >= 65 ? "warn" : ""; }

  // ---------- Pieces ----------
  function barHTML(b, read) {
    var fill = b && b.value > 0 ? Math.min(100, b.value) : 0;
    return '<div class="bar' + (b && b.gradient ? " grad" : "") + '"><i style="width:' + fill + '%"></i>' +
      (read ? '<u style="left:' + (read.frac * 100).toFixed(2) + '%"></u>' : "") + "</div>";
  }

  function valueHTML(b) {
    if (b && b.text) return '<div class="t-val">' + esc(b.text) + "</div>";
    if (!b || b.value < 0) return '<div class="t-val none">–</div>';
    return '<div class="t-val ' + sev(b.value) + '">' + b.value + "%</div>";
  }

  // One quota of an Antigravity account: label and value on one line, then the bar, then countdown and pace.
  function miniHTML(b, label, now) {
    if (!b) return '<div class="mini"></div>';
    var read = quotaRead(b, now);
    var val = b.value < 0 ? '<span class="m-val none">–</span>' : '<span class="m-val ' + sev(b.value) + '">' + b.value + "%</span>";
    var cd = countdownText(b, now);
    return '<div class="mini"><div class="m-top"><span class="m-label">' + esc(label) + "</span>" + val + "</div>" +
      barHTML(b, read) +
      '<div class="m-line"><span class="cd" data-reset="' + (b.reset || "") + '">' + esc(cd) + "</span>&nbsp;</div></div>";
  }

  function headHTML(c, brand, now) {
    var old = c.stale || (c.fetched && now - c.fetched > STALE_FETCH_MS);
    return '<div class="c-head"><img src="img/' + brand + '.png?v=' + assetVersion() + '" alt="">' +
      '<div class="c-name">' + esc(c.name) + "</div>" +
      (c.plan ? '<div class="badge">' + esc(c.plan) + "</div>" : "") +
      (c.fetched ? '<div class="c-time' + (old ? " old" : "") + '">' + hhmm(c.fetched) + "</div>" : "") + "</div>";
  }

  // Only when something is off: "plenty left" on every card is noise at this size.
  function statusHTML(c) {
    if (!c.status || !c.status.text || c.status.level === "ok") return "";
    return '<div class="status ' + esc(c.status.level) + '"><i></i><span>' + esc(c.status.text) + "</span></div>";
  }

  function geminiHTML(g) {
    if (!g) return "";
    var days = Number(g.runway);
    return '<div class="sec"><div class="sec-title">' + esc(g.title) +
      (g.tier ? '<span class="badge gem-badge">' + esc(g.tier) + "</span>" : "") + "</div>" +
      '<div class="gem-row"><div class="gem-bal"><b>' + esc(g.balance) + "</b><small>" + esc(g.balanceLabel) + "</small></div>" +
      (g.runway ? '<div class="gem-run' + (days <= 14 ? " warn" : "") + '"><b>' + esc(g.runway) + "</b><small>" + esc(g.runwayLabel) + "</small></div>" : "") +
      "</div></div>";
  }

  // ---------- Columns ----------
  // Every column is boxes of two numbers (an Antigravity account, a pair of quotas, resets, credit)
  // over one stats block, so the three columns read at the same scale.
  function dm(ms) { var d = new Date(ms); return d.getDate() + "/" + (d.getMonth() + 1); }

  // "Fable · tuần" reads as just "Fable" inside a box already titled with the quotas.
  function cellLabel(label) { return String(label || "").split(" · ")[0]; }

  function box(title, cells, extraClass) {
    return '<div class="acct' + (extraClass ? " " + extraClass : "") + '"><div class="acct-head"><div class="acct-name">' + esc(title) + "</div></div>" +
      '<div class="acct-row">' + cells + "</div></div>";
  }

  // A number without a bar (resets left, money spent), laid out like a quota cell.
  function plainCell(label, value, line) {
    return '<div class="mini"><div class="m-top"><span class="m-label">' + esc(label) + '</span><span class="m-val">' + esc(value) + "</span></div>" +
      '<div class="bar-gap"></div><div class="m-line">' + esc(line || "") + "&nbsp;</div></div>";
  }

  // An amount of money with its caption underneath (API credit); fraction null means no bar.
  function amountCell(value, fraction, line, small) {
    var bar = '<div class="bar-gap"></div>';
    if (fraction !== null) {
      var f = Math.max(0, Math.min(1, Number(fraction) || 0));
      bar = '<div class="bar"><i style="width:' + (f * 100).toFixed(1) + '%"></i></div>';
    }
    return '<div class="mini"><div class="m-top"><span class="m-val' + (small ? " sm" : "") + '">' + esc(value) + "</span></div>" +
      bar + '<div class="m-line">' + esc(line || "") + "&nbsp;</div></div>";
  }

  function textBox(title, text, level) {
    return '<div class="acct"><div class="acct-head"><div class="acct-name">' + esc(title) + "</div></div>" +
      '<div class="box-text ' + esc(level || "") + '">' + esc(text) + "</div></div>";
  }

  function subscriptionBoxes(c, now) {
    var boxes = [];
    var bars = ((c.accounts && c.accounts[0] && c.accounts[0].bars) || []);
    for (var i = 0; i < bars.length && boxes.length < 2; i += 2) {
      boxes.push(box(t("limits"), miniHTML(bars[i], cellLabel(bars[i].label), now) +
        (bars[i + 1] ? miniHTML(bars[i + 1], cellLabel(bars[i + 1].label), now) : '<div class="mini"></div>')));
    }
    var rc = c.resetCells || [];
    if (rc.length && boxes.length < 3) {
      var cells;
      if (rc.length >= 2) {
        cells = rc.slice(0, 2).map(function (r) { return plainCell(r.label, String(r.count), r.expires ? t("expires") + " " + dm(r.expires) : ""); }).join("");
      } else {
        cells = plainCell(rc[0].label, String(rc[0].count), rc[0].expires ? t("expires") + " " + dm(rc[0].expires) : "") + '<div class="mini"></div>';
      }
      boxes.push(box(t("resets"), cells));
    }
    if (c.credit && boxes.length < 3) {
      // Two amounts side by side do not fit next to labels ("$186.40" beside "$13.60"), so here the
      // amount stands alone on the top line and its label goes underneath; long pairs get smaller type.
      var small = (String(c.credit.value) + String(c.credit.spent || "")).length > 13;
      boxes.push(box(c.credit.label, amountCell(c.credit.value, c.credit.fraction, c.credit.of, small) +
        (c.credit.spent ? amountCell(c.credit.spent, null, c.credit.spentLabel || t("spent"), small) : '<div class="mini"></div>'), "money"));
    }
    if (boxes.length < 3 && c.status && c.status.text) boxes.push(textBox(t("forecast"), c.status.text, c.status.level));
    return boxes.join("");
  }

  function usageHTML(u) {
    if (!u || !u.stats || !u.stats.length) return "";
    return '<div class="sec"><div class="sec-title">' + esc(u.title) + "<em>" + esc(t("last24h")) + "</em></div>" +
      '<div class="metrics three">' + u.stats.slice(0, 3).map(function (m) {
        return '<div class="metric"><b>' + esc(m.value) + "</b><small>" + esc(m.label) + "</small></div>";
      }).join("") + "</div></div>";
  }

  function columnHTML(c, now, extra) {
    var brand = brandOf(c.brand);
    var accts = c.accounts || [];
    var body;
    if (c.login && accts.length <= 1) {
      body = '<div class="login"><b>' + esc(t("needsLogin")) + "</b><span>" + esc(t("loginHint")) + "</span></div>";
    } else if (accts.length > 1) {
      body = '<div class="accts">' + accts.slice(0, 3).map(function (a) {
        var bars = a.bars || [];
        var five = bars.filter(function (b) { return b.window === FIVE_HOURS; })[0];
        var week = bars.filter(function (b) { return b.window >= WEEK * 0.9; })[0];
        var msg = a.login ? t("needsLogin") : a.empty ? t("notConnected") : "";
        return '<div class="acct"><div class="acct-head"><div class="acct-name">' + esc(a.name) + "</div>" +
          (msg ? '<div class="acct-msg">' + esc(msg) + "</div>" : "") + "</div>" +
          (msg ? "" : '<div class="acct-row">' + miniHTML(five, t("fiveHours"), now) + miniHTML(week, t("week"), now) + "</div>") +
          "</div>";
      }).join("") + "</div>" + statusHTML(c);
    } else {
      body = '<div class="accts">' + subscriptionBoxes(c, now) + "</div>";
    }
    return '<section class="col ' + brand + '">' + headHTML(c, brand, now) + body + usageHTML(c.usage) + (extra || "") + "</section>";
  }

  function alertHTML(a) {
    if (!a) return "";
    return '<div class="alert ' + (a.level === "critical" ? "critical" : "") + '"><div class="alert-mark">!</div>' +
      '<div class="alert-text"><div class="alert-title">' + esc(a.title) + "</div>" +
      (a.detail ? '<div class="alert-detail">' + esc(a.detail) + "</div>" : "") + "</div></div>";
  }

  function render() {
    var now = Date.now();
    if (!snap) {
      document.body.classList.add("is-waiting");
      $("waiting-text").textContent = t("waiting");
      tick();
      return;
    }
    document.body.classList.remove("is-waiting");
    var cards = (snap.cards || []).slice(0, 3);
    var gem = geminiHTML(snap.gemini);
    var hasGoogle = cards.some(function (c) { return brandOf(c.brand) === "gemini"; });
    $("cols").innerHTML = cards.map(function (c) {
      return columnHTML(c, now, brandOf(c.brand) === "gemini" ? gem : "");
    }).join("") + (!hasGoogle && gem ? '<section class="col gemini">' + gem + "</section>" : "");
    $("alert").innerHTML = alertHTML(snap.alert);
    tick();
  }

  // Every second: clock, countdowns, connection line. Bars and pace readings are redrawn each minute.
  function tick() {
    var now = Date.now(), d = new Date(now);
    $("time").textContent = pad(d.getHours()) + ":" + pad(d.getMinutes());
    try {
      $("date").textContent = d.toLocaleDateString(lang === "en" ? "en-GB" : "vi-VN", { weekday: "long", day: "numeric", month: "long" });
    } catch (e) { $("date").textContent = ""; }

    var sync = $("sync");
    if (snap) {
      var old = !demo && now - receivedAt > OLD_AFTER_MS;
      sync.classList.toggle("old", old);
      sync.textContent = (old ? t("macAway") : t("updated")) + " " + hhmm(old ? receivedAt : snap.sent || receivedAt);
    } else {
      sync.textContent = "";
    }

    var els = document.querySelectorAll(".cd[data-reset]");
    for (var i = 0; i < els.length; i++) {
      var r = Number(els[i].getAttribute("data-reset")) || 0;
      if (r) els[i].textContent = countdownText({ reset: r }, now);
    }
  }

  // Numbers from a snapshot go into markup, so anything that should be a number is forced to one
  // (any sender on the network can join the receiver and send on this namespace).
  function num(v) { var n = Number(v); return isFinite(n) ? n : null; }
  function clean(data) {
    (data.cards || []).forEach(function (c) {
      c.fetched = num(c.fetched);
      if (c.credit) c.credit.fraction = num(c.credit.fraction) || 0;
      (c.resetCells || []).forEach(function (r) { r.count = num(r.count) || 0; r.expires = num(r.expires); });
      (c.accounts || []).forEach(function (a) {
        (a.bars || []).forEach(function (b) {
          var v = num(b.value);
          b.value = v == null ? -1 : Math.round(v);
          b.reset = num(b.reset);
          b.window = num(b.window) || 0;
        });
      });
    });
    data.sent = num(data.sent);
    return data;
  }

  function apply(data, at) {
    if (!data || typeof data !== "object" || !Array.isArray(data.cards)) return;
    snap = clean(data);
    receivedAt = at || Date.now();
    if (data.lang === "en" || data.lang === "vi") lang = data.lang;
    document.documentElement.lang = lang;
    render();
  }

  // ---------- Live update ----------
  // The keep-alive video keeps this page open for days, and reopening the Mac app only rejoins it,
  // so a deployed style change would never show. Poll index.html and swap in a newer stylesheet;
  // the logos follow the stylesheet's version.
  function assetVersion() {
    var link = document.querySelector('link[href^="receiver.css"]');
    var m = link && /v=(\d+)/.exec(link.getAttribute("href"));
    return m ? m[1] : "0";
  }

  function checkUpdate() {
    fetch("index.html?t=" + Date.now(), { cache: "no-store" })
      .then(function (r) { return r.ok ? r.text() : ""; })
      .then(function (html) {
        var m = /receiver\.css\?v=(\d+)/.exec(html);
        var link = document.querySelector('link[href^="receiver.css"]');
        if (!m || !link || m[1] === assetVersion()) return;
        link.setAttribute("href", "receiver.css?v=" + m[1]);
        if (snap) render();
      })
      .catch(function () {});
  }

  // ---------- Start ----------
  fit();
  render();
  setInterval(tick, 1000);
  setInterval(function () { if (snap) render(); }, 60 * 1000);
  setInterval(checkUpdate, 3 * 60 * 1000);

  if (demo) {
    // ?snapshot=<url>: a snapshot the Mac app saved (cast-snapshot.json), to design with real numbers.
    var src = params.get("snapshot");
    if (src) {
      fetch(src).then(function (r) { return r.json(); })
        .then(function (d) { apply(d, Date.now()); })
        .catch(function () { apply(demoSnapshot(), Date.now()); });
    } else {
      apply(demoSnapshot(), Date.now());
    }
    return;
  }

  // Nothing is kept on the device: the Mac sends a snapshot as soon as it joins.
  try { localStorage.removeItem(STORE_KEY); } catch (e) { /* storage unavailable */ }

  var context = cast.framework.CastReceiverContext.getInstance();
  context.addCustomMessageListener(NS, function (event) {
    var data = event.data;
    if (typeof data === "string") { try { data = JSON.parse(data); } catch (e) { return; } }
    if (data && data.type === "snapshot") {
      apply(data.snapshot, Date.now());
    } else if (data && data.type === "keepalive") {
      keepAlive();
    }
  });

  // Keep the screen. A Nest Hub closes a cast app and goes back to its photo frame about 10 minutes
  // after anything stopped playing, even with disableIdleTimeout. A still image (what Home Assistant's
  // receiver loads) sits PAUSED and was not enough here (2026-11-13). So a silent black video plays
  // in a hidden <cast-media-player>, 10 minutes long and loaded again as it ends: the player is
  // always PLAYING. A check every minute restarts it if anything else stopped it.
  var playerManager = context.getPlayerManager();
  var loading = false;
  function keepAlive() {
    if (loading) return;
    loading = true;
    try {
      var req = new cast.framework.messages.LoadRequestData();
      req.media = new cast.framework.messages.MediaInformation();
      req.media.contentId = new URL("media/keepalive.mp4", location.href).href;
      req.media.contentType = "video/mp4";
      req.media.streamType = cast.framework.messages.StreamType.BUFFERED;
      req.media.metadata = new cast.framework.messages.GenericMediaMetadata();
      req.media.metadata.title = "AIUsage";
      req.autoplay = true;
      var p = playerManager.load(req);
      var done = function (ok, why) { loading = false; report(ok, why); };
      if (p && p.then) {
        p.then(function () { done(true, ""); }, function (e) { done(false, String(e && (e.detailedErrorCode || e.reason || e.type) || e)); });
      } else {
        loading = false;
      }
    } catch (e) { loading = false; report(false, String(e)); }
  }
  // Tells connected senders how the last keep-alive went (the Mac app ignores it; useful when testing).
  function report(ok, why) {
    try { context.sendCustomMessage(NS, undefined, { type: "keepalive", ok: ok, error: why, state: playerManager.getPlayerState() }); } catch (e) { /* no sender */ }
  }
  context.addEventListener(cast.framework.system.EventType.READY, function () {
    keepAlive();
    setInterval(function () {
      var st = playerManager.getPlayerState();
      if (st !== "PLAYING" && st !== "BUFFERING") keepAlive();
    }, 60 * 1000);
  });
  // The video ended (or failed): start it again right away.
  playerManager.addEventListener(cast.framework.events.EventType.MEDIA_STATUS, function (event) {
    var st = event.mediaStatus;
    if (st && st.playerState === "IDLE" && st.idleReason && st.idleReason !== "INTERRUPTED") {
      setTimeout(keepAlive, 500);
    }
  });
  // The framework adds media touch controls for the player; this page has nothing to control.
  new MutationObserver(function () {
    var els = document.getElementsByTagName("touch-controls");
    for (var i = els.length - 1; i >= 0; i--) els[i].parentNode.removeChild(els[i]);
  }).observe(document.documentElement, { childList: true, subtree: true });

  var options = new cast.framework.CastReceiverOptions();
  options.disableIdleTimeout = true;        // a dashboard, not a player: stay on screen
  options.maxInactivity = 3600;             // keep the sender through short Wi-Fi drops
  options.customNamespaces = {};
  options.customNamespaces[NS] = cast.framework.system.MessageType.JSON;
  options.statusText = "AIUsage";
  context.start(options);

  // ---------- Sample data (demo mode only; every number and name here is made up) ----------
  function demoSnapshot() {
    var now = Date.now(), H = 3600 * 1000, D = 24 * H;
    var vi = lang === "vi";
    function q(label, value, reset, win, grad) { return { label: label, value: value, reset: reset, window: win, gradient: !!grad }; }
    return {
      v: 2, lang: lang, sent: now - 2 * 60 * 1000,
      cards: [
        { id: "claude", brand: "claude", name: "Claude", plan: "ULTRA", fetched: now - 120000,
          status: { level: "ok", text: vi ? "Dư dả, dùng chậm hơn nhịp" : "Plenty left, slower than pace" },
          accounts: [{ name: "", bars: [
            q(vi ? "Tuần" : "Week", 58, now + 2 * D + 12 * H, WEEK),
            q(vi ? "Fable · tuần" : "Fable · week", 23, now + 2 * D + 12 * H, WEEK)] }],
          credit: { label: "API credit", value: "$186.40", of: vi ? "trên $200.00" : "of $200.00", fraction: 0.932,
                    note: vi ? "Chi tháng này $13.60" : "Spent this month $13.60" },
          resets: [{ title: vi ? "Còn 1 lượt reset Fable" : "Fable resets left: 1",
                     detail: vi ? "Chỉ hồi hạn mức Fable · hết hạn 8/3/2027" : "Refills only the Fable allowance · expires 8/3/2027" }] },
        { id: "chatgpt", brand: "openai", name: "ChatGPT", plan: "PLUS", fetched: now - 120000,
          status: { level: "fast", text: vi ? "Tuần: dự kiến hết sáng thứ 7" : "Week: runs out Saturday morning" },
          accounts: [{ name: "", bars: [
            q(vi ? "5 giờ" : "5 hours", 71, now + 80 * 60000, FIVE_HOURS),
            q(vi ? "Tuần" : "Week", 37, now + 4 * D + 21 * H, WEEK)] }],
          resets: [{ title: vi ? "Còn 2 lượt reset" : "Resets left: 2",
                     detail: vi ? "Đặt lại giới hạn tuần và 5 giờ" : "Restores the weekly and 5-hour limits" }],
          statsTitle: "Codex CLI",
          stats: [{ value: "64", label: vi ? "lượt" : "turns" }, { value: "21.4M", label: "token" },
                  { value: "68%", label: "context max" }, { value: "1m", label: vi ? "mỗi lượt" : "per turn" }] },
        { id: "antigravity", brand: "gemini", name: "Antigravity", plan: "AI PRO", fetched: now - 120000,
          status: { level: "ok", text: vi ? "Dư dả, dùng chậm hơn nhịp" : "Plenty left, slower than pace" },
          accounts: [
            { name: "demo.main", bars: [q("5h", 12, now + 3 * H + 32 * 60000, FIVE_HOURS, true), q("W", 41, now + 3 * D + 10 * H, WEEK, true)] },
            { name: "demo.work", bars: [q("5h", 63, now + 86 * 60000, FIVE_HOURS, true), q("W", 71, now + 2 * D + H, WEEK, true)] },
            { name: "demo.lab", bars: [q("5h", -1, null, FIVE_HOURS, true), q("W", 18, now + 5 * D + 9 * H, WEEK, true)] }
          ] }
      ],
      alert: { level: "warning", title: vi ? "ChatGPT Tuần: dự kiến hết sáng thứ 7" : "ChatGPT Week: runs out Saturday morning",
               detail: vi ? "Đang dùng 37%, nhanh hơn nhịp đều. Reset sau 4d 21h." : "37% used, faster than the even pace. Resets in 4d 21h." },
      gemini: { title: "Gemini API", tier: "Paid 1", balance: "$84.20", balanceLabel: vi ? "Số dư credit" : "Credit balance",
                runway: "61", runwayLabel: vi ? "ngày còn đủ" : "days left",
                stats: [{ value: "$1.18", label: vi ? "hôm nay" : "today" }, { value: "$9.64", label: vi ? "7 ngày" : "7 days" },
                        { value: "$31.27", label: vi ? "tháng này" : "this month" }] }
    };
  }
})();

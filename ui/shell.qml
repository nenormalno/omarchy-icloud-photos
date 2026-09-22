import QtQuick
import QtQuick.Controls.Basic
import Quickshell
import Quickshell.Io

// omarchy-icloud-photos: the last week of an iCloud Photos library in one window.
//
// All data comes from bin/omarchy-icloud-photos-sync, which writes index.json and
// status.json under ~/.cache/omarchy-icloud-photos. This file only renders them and
// can ask the script to run again. Nothing here writes to the library.
ShellRoot {
  id: root

  readonly property string cacheDir:
    (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy-icloud-photos"
  // Qt.resolvedUrl refuses to leave the shell directory (it returns
  // qrc:/qs-blackhole), so the scripts are found from shellDir instead.
  readonly property string binDir: Quickshell.shellDir + "/../bin"
  readonly property string syncScript: binDir + "/omarchy-icloud-photos-sync"
  readonly property string helperScript: binDir + "/omarchy-icloud-photos-helper"
  readonly property string infoScript: binDir + "/omarchy-icloud-photos-info"
  readonly property string configPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy-icloud-photos/config"

  property var items: []
  property var library: []       // full index; items is library narrowed by dateFilter
  property string dateFilter: "" // "" | YYYY-MM | YYYY-MM-DD
  property var days: []          // [{label, indices: [int]}]
  property int selected: -1
  // OMARCHY_ICLOUD_PHOTOS_TOUR=1: scroll the grid from top to bottom by itself and
  // open one photo at the end. Used to record the demo video.
  readonly property bool tour: Quickshell.env("OMARCHY_ICLOUD_PHOTOS_TOUR") === "1"
  property bool tourStarted: false
  // Multi-selection: ids of the checked items and the index where a shift
  // range starts. The cursor (`selected`) always counts as selected too.
  property var checked: ({})
  property int checkedCount: 0
  property int anchor: -1
  property bool viewerOpen: false
  property bool helpOpen: false
  property bool jumpOpen: false
  property bool demo: false
  property var pinnedMonths: []
  property string historySince: ""
  property int olderChain: 0
  property real olderChainAdded: 0
  // Set while a date jump is downloading a month; consumed when the index reloads.
  property string pendingJump: ""
  // Scrolling past the top fetches the next older stretch. The base keeps the
  // photos you were looking at in place while that stretch is prepended.
  property bool loadingOlder: false
  // Spinner in the top slot, kept up for the whole week chain.
  property bool showOlderSpinner: false
  // One older-week fetch at a time. Scrolling away (down) rearms the next one,
  // so moving back and forth does not stack loads.
  property bool olderActive: false
  property bool olderPull: true
  property real olderDown: 0
  property real olderBarY: -1
  property bool olderLatch: false
  property real olderBaseY: 0
  property real olderBaseH: -1
  property var fetchQueue: []
  property int fetchAt: 0
  property var fetchAction: null
  property string afterFetchId: ""
  property string fetchFailedId: ""
  property bool fetching: false
  // Id of the item whose original is downloading, so the viewer can spin
  // on that thumbnail without waiting to open.
  property string fetchingId: ""
  // Files from the original just downloaded, applied even if a reindex is
  // blocked by the week sync still holding the lock.
  property var pendingOriginal: null
  // Details panel in the viewer (`i`): rows for the item it was fetched for.
  property bool infoOpen: false
  property var infoRows: []
  property string infoForId: ""
  property var status: ({ state: "unknown", message: "", at: "" })
  property bool indexMissing: false
  // Apple ID from the config file; empty until the first sign-in.
  property string appleId: ""
  property int rangeDays: 30
  property bool configLoaded: false
  // The sign-in card shows on first run and whenever the session has expired.
  readonly property bool needLogin: configLoaded && (appleId === "" || status.state === "auth-required")
  // Keep the grid scrolled to the newest items (the bottom) until the user
  // moves away, so a fresh sync lands in view like on the phone.
  // root.tour, not tour: the animation below has id `tour`, and an id wins
  // from a property in the same scope.
  property bool pinBottom: !root.tour   // the tour starts at the top and scrolls down
  property bool ctrlHeld: false
  // True while the grid is being rebuilt, so a re-created selected thumb
  // does not yank the view towards itself before the layout has settled.
  property bool suppressReveal: false

  // Thumbnail size, driven by the slider in the footer and remembered.
  property int cell: settings.cell
  // Item waiting for a yes in the delete dialog, and the last one that went
  // so it can be undone with the toast button or `u`.
  property var pendingDelete: null
  property var lastDeleted: []
  property int batchTotal: 0
  property int batchDone: 0
  property bool trashBusy: false
  // Queue of {action, item} for the helper, run one at a time. Confirming a
  // delete removes the item from the grid right away and queues the work;
  // the toast at the bottom reports progress and offers Undo when done.
  property var jobs: []
  property bool undoAfterCurrent: false
  property bool reindexDirty: false
  readonly property int gap: 8
  readonly property var current: (selected >= 0 && selected < items.length) ? items[selected] : null

  // Everything an action applies to: the checked items in grid order, or
  // just the cursor when nothing is checked.
  function targets() {
    if (checkedCount === 0) return current ? [current] : [];
    var out = [];
    for (var i = 0; i < items.length; i++) if (checked[items[i].id]) out.push(items[i]);
    return out;
  }

  function clearChecked() {
    checked = ({});
    checkedCount = 0;
    anchor = selected;
  }

  function setChecked(map) {
    var n = 0;
    for (var k in map) n++;
    checked = map;
    checkedCount = n;
  }

  // Shift: check every item between the anchor and the cursor.
  function checkRange(from, to) {
    if (from < 0) from = to;
    var map = {};
    var a = Math.min(from, to), b = Math.max(from, to);
    for (var i = a; i <= b; i++) map[items[i].id] = true;
    setChecked(map);
  }

  function toggleChecked(index) {
    var map = Object.assign({}, checked);
    var id = items[index].id;
    if (map[id]) delete map[id]; else map[id] = true;
    setChecked(map);
    anchor = index;
  }

  function checkAll() {
    var map = {};
    for (var i = 0; i < items.length; i++) map[items[i].id] = true;
    setChecked(map);
  }
  readonly property bool busy: sync.running || status.state === "syncing" || status.state === "indexing"

  Theme { id: appTheme }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: appTheme.apply(text())
    onFileChanged: reload()
  }

  FileView {
    id: indexFile
    path: root.cacheDir + "/index.json"
    watchChanges: true
    printErrors: false
    onLoaded: { root.indexMissing = false; root.applyIndex(text()); if (root.tour && !root.tourStarted) tourKickoff.start(); }
    onLoadFailed: { root.indexMissing = true; if (!sync.running && root.appleId !== "") sync.running = true; }
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.appleId = root.parseAppleId(text());
      root.rangeDays = root.parseDays(text());
      root.demo = /^\s*DEMO=["']?1/m.test(String(text()));
      root.configLoaded = true;
    }
    onLoadFailed: { root.appleId = ""; root.configLoaded = true; }
    onFileChanged: reload()
  }

  // Sign-in runs the helper with the password on stdin; Apple's 2FA code
  // goes down the same pipe when the helper asks for it.
  Process {
    id: login
    running: false
    stdinEnabled: true
    property string password: ""
    onStarted: { write(password + "\n"); password = ""; }
    stdout: SplitParser {
      onRead: data => root.loginLine(data)
    }
    onExited: (code, status) => {
      if (loginCard.busy) {
        loginCard.busy = false;
        if (loginCard.error === "") loginCard.error = "The sign-in helper stopped without an answer";
      }
    }
  }

  FileView {
    id: rangesFile
    path: root.cacheDir + "/ranges.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text());
        root.pinnedMonths = parsed.months || [];
        root.historySince = parsed.since || "";
      } catch (e) {
        root.pinnedMonths = [];
        root.historySince = "";
      }
    }
    onFileChanged: reload()
  }

  FileView {
    id: statusFile
    path: root.cacheDir + "/status.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.status = JSON.parse(text()); } catch (e) {}
    }
    onFileChanged: reload()
  }

  Process {
    id: sync
    command: [root.syncScript]
    running: false
    onExited: (code, status) => {
      root.traceLine("sync exited code=" + code + " status=" + status
        + (root.loadingOlder ? " (older week)" : ""));
      sync.command = [root.syncScript];
      indexFile.reload();
      statusFile.reload();
      rangesFile.reload();
      if (root.pendingJump) jumpFallback.restart();
      if (root.loadingOlder) olderDone.restart();
    }
  }

  // ui.log, next to sync.log. One long-lived writer so a line cannot be lost
  // between process starts.
  Process {
    id: uiLog
    stdinEnabled: true
    command: ["bash", "-c", "umask 077; mkdir -p -- \"$1\"; touch \"$1/ui.log\"; exec cat >> \"$1/ui.log\"", "log", root.cacheDir]
    running: true
  }

  function traceLine(msg) {
    var line = Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm:ss") + " " + msg + "\n";
    console.log(msg);
    if (uiLog.running) uiLog.write(line);
  }

  Timer {
    id: olderDone
    interval: 1500
    onTriggered: {
      var added = root.olderBaseH >= 0 ? Math.max(0, grid.contentHeight - root.olderBaseH) : 0;
      root.olderChainAdded += added;
      root.olderChain++;
      root.loadingOlder = false;
      root.olderBaseH = -1;
      root.olderLatch = false;
      if (toast.busy) toast.opacity = 0;
      // Keep a screen of older photos buffered. A short or empty week
      // pulls the next one; four weeks is the most one gesture will fetch.
      var more = root.olderChain < 4 && root.olderChainAdded < grid.height * 0.85;
      if (!more || !root.maybeLoadOlder(true)) {
        root.showOlderSpinner = false;
        root.olderActive = false;
      }
    }
  }

  Timer {
    id: jumpFallback
    interval: 500
    onTriggered: {
      if (!root.pendingJump) return;
      var want = root.pendingJump;
      root.pendingJump = "";
      root.finishJump(want);
    }
  }

  Process {
    id: fetcher
    running: false
    property string output: ""
    stdout: StdioCollector {
      onStreamFinished: fetcher.output = text
    }
    onExited: root.fetchExited(fetcher.output)
  }

  Process { id: opener }
  Process {
    id: infoProc
    property string forId: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var rows = [];
        try { rows = JSON.parse(text); } catch (e) {}
        if (root.current && root.current.id === infoProc.forId && root.current.shared)
          rows = [["Library", "Shared"]].concat(rows);
        root.infoRows = rows;
        root.infoForId = infoProc.forId;
      }
    }
  }
  Process {
    id: wallpaper
    stdout: StdioCollector {
      onStreamFinished: toast.show(text.trim().length > 0 ? text.trim() : "Set as wallpaper", 2500)
    }
  }
  Process {
    id: saver
    stdout: StdioCollector {
      onStreamFinished: {
        var names = text.trim().split("\n").filter(function (n) { return n.length > 0; });
        if (names.length === 1) toast.show("Saved to ~/Downloads/" + names[0], 3000);
        else if (names.length > 1) toast.show("Saved " + names.length + " files to ~/Downloads", 3000);
      }
    }
  }
  Process { id: copier }

  // Re-index in the background after a delete or restore so index.json
  // matches what is on disk again; the FileView picks the result up.
  Process {
    id: reindex
    command: [root.syncScript, "--index-only"]
    running: false
    onExited: {
      if (root.reindexDirty) { root.reindexDirty = false; running = true; return; }
      if (root.fetchAction) indexFile.reload();
    }
  }

  Process {
    id: trash
    running: false
    property string action: ""
    property var subject: null
    stdout: StdioCollector {
      onStreamFinished: root.trashFinished(trash.action, trash.subject, text)
    }
    // If the helper could not start or died without output, stdout never
    // finishes; settle the dialog anyway shortly after the process is gone.
    onRunningChanged: if (!running) settle.restart()
    onStarted: watchdog.restart()
  }
  Timer {
    id: settle
    interval: 700
    onTriggered: if (root.trashBusy) root.trashFinished(trash.action, trash.subject, "")
  }
  Timer {
    id: watchdog
    interval: 120000
    onTriggered: if (root.trashBusy) { trash.running = false; root.trashFinished(trash.action, trash.subject, ""); }
  }

  FileView {
    id: settingsFile
    path: root.cacheDir + "/settings.json"
    printErrors: false
    JsonAdapter {
      id: settings
      property int cell: 176
    }
  }

  function applyIndex(raw) {
    var list;
    try { list = JSON.parse(raw); } catch (e) { return; }
    if (!Array.isArray(list)) return;
    library = list;
    var keepId = current ? current.id : null;
    if (root.pendingJump) {
      var want = root.pendingJump;
      root.pendingJump = "";
      root.finishJump(want);
    } else root.showFiltered(keepId);
    if (root.fetchAction && root.afterFetchId) root.finishFetch();
  }

  function groupDays(list) {
    var groups = [];
    var byDate = {};
    for (var i = 0; i < list.length; i++) {
      var d = list[i].date;
      if (!byDate[d]) {
        byDate[d] = { label: dayLabel(list[i]), indices: [] };
        groups.push(byDate[d]);
      }
      byDate[d].indices.push(i);
    }
    return groups;
  }

  function dayLabel(it) {
    var d = new Date(it.ts * 1000);
    var today = new Date(); today.setHours(0, 0, 0, 0);
    var day = new Date(d); day.setHours(0, 0, 0, 0);
    var diff = Math.round((today - day) / 86400000);
    if (diff === 0) return "Today";
    if (diff === 1) return "Yesterday";
    var s = d.toLocaleDateString(Qt.locale("en_GB"), "dddd d MMMM");
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function parseDays(raw) {
    var m = String(raw || "").match(/^\s*DAYS=["']?(\d+)/m);
    return m ? parseInt(m[1]) : 30;
  }

  function rangeLabel() {
    var d = rangeDays;
    var base;
    if (d === 7) base = "last week";
    else if (d === 14) base = "last two weeks";
    else if (d >= 28 && d <= 31) base = "last month";
    else if (d >= 89 && d <= 93) base = "last three months";
    else base = "last " + d + " days";
    if (historySince) {
      var since = parseIso(historySince);
      var cutoff = new Date();
      cutoff.setHours(0, 0, 0, 0);
      cutoff.setDate(cutoff.getDate() - rangeDays);
      if (since < cutoff)
        return "since " + since.toLocaleDateString(Qt.locale("en_GB"), "d MMM");
    }
    return base;
  }

  function pad2(n) { return (n < 10 ? "0" : "") + n; }

  function parseIso(s) {
    var p = String(s).split("-");
    return new Date(parseInt(p[0], 10), parseInt(p[1], 10) - 1, parseInt(p[2], 10));
  }

  function isoDate(d) {
    return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
  }

  function weekTitle(from, to) {
    var a = parseIso(from), b = parseIso(to);
    var mon = b.toLocaleDateString(Qt.locale("en_GB"), "MMM");
    if (a.getMonth() === b.getMonth() && a.getFullYear() === b.getFullYear())
      return a.getDate() + "–" + b.getDate() + " " + mon;
    return a.toLocaleDateString(Qt.locale("en_GB"), "d MMM") + " – " + b.toLocaleDateString(Qt.locale("en_GB"), "d MMM");
  }

  // The seven days immediately before the oldest day already requested.
  function olderRange() {
    if (items.length === 0) return null;
    var boundary = items[0].date;
    if (historySince && historySince < boundary) boundary = historySince;
    var edge = parseIso(boundary);
    if (isNaN(edge.getTime())) return null;
    var end = new Date(edge.getFullYear(), edge.getMonth(), edge.getDate() - 1);
    var start = new Date(end.getFullYear(), end.getMonth(), end.getDate() - 6);
    return { from: isoDate(start), to: isoDate(end) };
  }

  function noteOlderDown(px) {
    if (px <= 0) return;
    olderDown = Math.min(400, olderDown + px);
    if (olderDown >= 120) olderPull = true;
  }

  function maybeLoadOlder(chained) {
    if (demo || needLogin || viewerOpen || jumpOpen || helpOpen || dateFilter) return false;
    // A scroll up starts one chain. Further ups do nothing until the user
    // has scrolled down and this chain has finished.
    if (!chained && (olderActive || !olderPull)) return false;
    if (loadingOlder || sync.running || olderLatch || items.length === 0) return false;
    var range = olderRange();
    if (!range) return false;
    if (!chained) {
      olderChain = 0;
      olderChainAdded = 0;
      olderPull = false;
      olderDown = 0;
      olderActive = true;
    }
    pinBottom = false;
    grid.restoreY = -1;
    showOlderSpinner = true;
    olderLatch = true;
    loadingOlder = true;
    olderBaseY = grid.contentY;
    olderBaseH = grid.contentHeight;
    toast.showBusy("Loading " + weekTitle(range.from, range.to) + "…");
    traceLine((chained ? "older week (chain) " : "older week ") + range.from + " .. " + range.to);
    startSync(range.from, range.to);
    return true;
  }

  function indexOfDate(date) {
    var source = sourceItems();
    for (var i = 0; i < source.length; i++) if (source[i].date === date) return i;
    return -1;
  }

  function firstInMonth(month) {
    var source = sourceItems();
    for (var i = 0; i < source.length; i++) if (String(source[i].date).indexOf(month) === 0) return i;
    return -1;
  }

  function nearestInMonth(month, date) {
    var source = sourceItems();
    var target = Date.parse(date);
    var best = -1, bestDiff = 1e15;
    for (var i = 0; i < source.length; i++) {
      if (String(source[i].date).indexOf(month) !== 0) continue;
      var diff = Math.abs(Date.parse(source[i].date) - target);
      if (diff < bestDiff) { bestDiff = diff; best = i; }
    }
    return best;
  }

  function monthPinned(month) {
    for (var i = 0; i < pinnedMonths.length; i++) if (pinnedMonths[i] === month) return true;
    return false;
  }

  function monthBounds(text) {
    var m = text.slice(0, 7);
    var parts = m.split("-");
    var y = parseInt(parts[0], 10), mo = parseInt(parts[1], 10);
    var last = new Date(y, mo, 0).getDate();
    return {
      month: m,
      from: m + "-01",
      to: m + "-" + (last < 10 ? "0" : "") + last,
      day: text.length >= 10 ? text.slice(0, 10) : ""
    };
  }

  function sourceItems() { return library.length ? library : items; }

  function dayChoices() {
    var source = sourceItems();
    var out = [];
    var seen = {};
    for (var i = source.length - 1; i >= 0; i--) {
      var d = source[i].date;
      if (!d || seen[d]) continue;
      seen[d] = true;
      out.push({ label: dayLabel(source[i]), date: d });
    }
    return out;
  }

  function filterLabel() {
    if (/^\d{4}-\d{2}-\d{2}$/.test(dateFilter)) {
      var d = parseIso(dateFilter);
      return d.toLocaleDateString(Qt.locale("en_GB"), "d MMMM yyyy");
    }
    if (/^\d{4}-\d{2}$/.test(dateFilter)) {
      var p = dateFilter.split("-");
      var month = new Date(parseInt(p[0], 10), parseInt(p[1], 10) - 1, 1);
      var s = month.toLocaleDateString(Qt.locale("en_GB"), "MMMM yyyy");
      return s.charAt(0).toUpperCase() + s.slice(1);
    }
    return dateFilter;
  }

  // Narrow the grid to a day (YYYY-MM-DD) or a month (YYYY-MM). An empty
  // filter shows the whole loaded library again.
  function setDateFilter(filter) {
    dateFilter = filter || "";
    clearChecked();
    pinBottom = dateFilter === "";
    showFiltered(null);
    if (dateFilter) grid.contentY = 0;
  }

  function showFiltered(keepId) {
    var source = library;
    var list = [];
    for (var i = 0; i < source.length; i++)
      if (!dateFilter || String(source[i].date).indexOf(dateFilter) === 0) list.push(source[i]);
    var idx = list.length ? list.length - 1 : -1;
    if (keepId) for (var j = 0; j < list.length; j++) if (list[j].id === keepId) { idx = j; break; }
    rebuild(list, idx);
  }

  function finishJump(want) {
    if (indexOfDate(want) >= 0) { setDateFilter(String(want).length >= 10 ? want : String(want).slice(0, 7)); return; }
    var month = String(want).slice(0, 7);
    if (firstInMonth(month) < 0) { toast.show("No photos in " + month, 2500); return; }
    if (String(want).length >= 10) {
      var idx = nearestInMonth(month, want);
      toast.show("No photos on " + want, 2500);
      if (idx >= 0) setDateFilter(sourceItems()[idx].date);
      return;
    }
    setDateFilter(month);
  }

  function pickDay(date) {
    jumpOpen = false;
    if (indexOfDate(date) >= 0) setDateFilter(date);
  }

  function goToDate(text) {
    var raw = String(text || "").trim();
    // A partial prefix (2026, 2026-09, 2026-09-2) filters what is already loaded.
    if (!/^\d{4}-\d{2}(-\d{2})?$/.test(raw)) {
      if (/^\d{4}(-\d{0,2}(-\d{0,2})?)?$/.test(raw)) {
        var source = sourceItems();
        for (var i = 0; i < source.length; i++) {
          if (String(source[i].date).indexOf(raw) === 0) {
            jumpOpen = false;
            setDateFilter(raw);
            return;
          }
        }
      }
      toast.show("No photos match " + raw, 2500);
      return;
    }
    var b = monthBounds(raw);
    jumpOpen = false;
    if (b.day && indexOfDate(b.day) >= 0) { setDateFilter(b.day); return; }
    var inMonth = firstInMonth(b.month);
    if (inMonth >= 0 || monthPinned(b.month)) {
      if (inMonth < 0) { toast.show("No photos in " + b.month, 2500); return; }
      if (b.day) {
        toast.show("No photos on " + b.day, 2500);
        var idx = nearestInMonth(b.month, b.day);
        if (idx >= 0) setDateFilter(sourceItems()[idx].date);
        return;
      }
      setDateFilter(b.month);
      return;
    }
    if (demo) { toast.show("The demo library does not reach iCloud", 3000); return; }
    if (sync.running) { toast.show("A sync is already running", 2500); return; }
    pendingJump = b.day || b.from;
    startSync(b.from, b.to);
  }

  function parseAppleId(raw) {
    var m = String(raw || "").match(/^\s*APPLE_ID=["']?([^"'\n]+)/m);
    return m ? m[1].trim() : "";
  }

  function startLogin(username, password) {
    login.password = password;
    login.command = [root.helperScript, "login", "--username", username, "--save-config"];
    login.running = true;
  }

  function loginLine(line) {
    var msg = null;
    try { msg = JSON.parse(String(line).trim()); } catch (e) { return; }
    if (msg.step === "2fa") {
      loginCard.busy = false;
      loginCard.step = "code";
    } else if (msg.step === "retry") {
      loginCard.error = msg.message || "Trying again…";
    } else if (msg.ok) {
      loginCard.busy = false;
      loginCard.reset();
      root.appleId = msg.username;
      root.status = { state: "ok", message: "", at: "" };
      toast.show("Signed in as " + msg.username);
      keys.forceActiveFocus();
      startSync();
    } else if (msg.error) {
      loginCard.busy = false;
      loginCard.error = msg.error;
      if (loginCard.step === "code") loginCard.step = "credentials";
    }
  }

  function syncedLabel() {
    if (busy) {
      // The sync script says what it is doing; the count grows as files land.
      var what = status.state === "indexing" ? (status.message || "Building thumbnails") : "Syncing";
      var n = status.count > 0 ? "  " + status.count : "";
      return what + "…" + n;
    }
    if (!status.at) return "";
    var d = new Date(status.at);
    if (isNaN(d.getTime())) return "";
    var today = new Date(); today.setHours(0, 0, 0, 0);
    var same = d >= today;
    return "synced " + (same ? "" : d.toLocaleDateString(Qt.locale("en_GB"), "d MMM ") + "at ")
      + d.toLocaleTimeString(Qt.locale("en_GB"), "HH:mm");
  }

  function move(delta, extend) {
    if (items.length === 0) return;
    pinBottom = false;
    var next = Math.max(0, Math.min(items.length - 1, selected + delta));
    if (extend) {
      if (anchor < 0 || checkedCount === 0) anchor = selected;
      selected = next;
      checkRange(anchor, selected);
    } else {
      selected = next;
      if (checkedCount > 0) clearChecked();
      anchor = selected;
    }
  }

  function jumpTo(index, extend) {
    if (items.length === 0) return;
    pinBottom = false;
    if (extend) {
      if (anchor < 0 || checkedCount === 0) anchor = selected;
      selected = index;
      checkRange(anchor, selected);
    } else {
      selected = index;
      if (checkedCount > 0) clearChecked();
      anchor = selected;
    }
  }

  function openCurrent() {
    if (!current) return;
    withOriginals(targets(), function () {
      if (!root.current) return;
      opener.command = ["xdg-open", root.current.kind === "video" ? root.current.video : root.current.path];
      opener.running = true;
    });
  }

  function openViewer() {
    if (!current) return;
    traceLine("open " + current.name + " needsOriginal=" + current.needsOriginal
      + " record=" + (current.record ? "yes" : "no"));
    viewerOpen = true;
    keys.forceActiveFocus();
    if (current.needsOriginal && current.id !== fetchFailedId)
      withOriginals([current], function () {});
  }

  function copyCurrent() {
    withOriginals(targets(), function () { root.copyCurrentNow(); });
  }

  function copyCurrentNow() {
    var list = targets();
    if (list.length === 0) return;
    if (list.length > 1) {
      // A list of files: file managers paste them as copies, chat apps as
      // attachments. Plain text gets the paths, one per line.
      var uris = list.map(function (it) { return "file://" + encodeURI(it.kind === "video" ? it.video : it.path); });
      copier.command = ["bash", "-c", 'printf "%s\n" "$@" | wl-copy --type text/uri-list', "_"].concat(uris);
      copier.running = true;
      toast.show("Copied " + list.length + " files");
      return;
    }
    var src = current.kind === "video" ? current.thumb : current.preview;
    var mime = /\.png$/i.test(src) ? "image/png" : "image/jpeg";
    copier.command = ["bash", "-c", 'wl-copy --type "$1" < "$2"', "_", mime, src];
    copier.running = true;
    toast.show("Copied to clipboard");
  }

  // Save to ~/Downloads in a format anything can open: HEIC becomes a
  // full-size JPEG, HDR video becomes its SDR MP4 copy, other video is
  // remuxed to MP4 without re-encoding, JPEG and PNG are copied as they are.
  // Never overwrites: a taken name gets a numbered suffix.
  function saveToDownloads() {
    withOriginals(targets(), function () { root.saveToDownloadsNow(); });
  }

  function saveToDownloadsNow() {
    var list = targets();
    if (list.length === 0) return;
    var args = [];
    for (var i = 0; i < list.length; i++) {
      var it = list[i];
      if (it.kind === "video") args.push(it.video, /\.mp4$/i.test(it.video) ? "copy" : "remux");
      else if (/\.(heic|heif|tif|tiff|dng)$/i.test(it.path)) args.push(it.path, "jpeg");
      else args.push(it.path, "copy");
    }
    saver.command = ["bash", "-c", '
      mkdir -p "$HOME/Downloads"
      while [ $# -ge 2 ]; do
        src="$1"; how="$2"; shift 2
        name=$(basename "$src"); base="${name%.*}"
        case "$how" in jpeg) ext=jpg ;; remux) ext=mp4 ;; *) ext="${name##*.}" ;; esac
        n=1; dest="$HOME/Downloads/$base.$ext"
        while [ -e "$dest" ]; do dest="$HOME/Downloads/$base-$n.$ext"; n=$((n+1)); done
        case "$how" in
          jpeg)  magick "$src" -auto-orient -quality 92 "$dest" ;;
          remux) ffmpeg -v error -y -i "$src" -c copy -movflags +faststart "$dest" || ffmpeg -v error -y -i "$src" -c:v libx264 -preset veryfast -crf 20 -c:a aac "$dest" ;;
          *)     cp -p "$src" "$dest" ;;
        esac && touch -r "$src" "$dest" && basename "$dest"
      done', "_"].concat(args);
    saver.running = true;
  }

  // W: the current photo becomes the Omarchy background. HEIC first becomes
  // a full-size JPEG in the cache, since the shell cannot decode HEIC.
  function setWallpaper() {
    if (!current || current.kind === "video") return;
    withOriginals([current], function () { root.setWallpaperNow(); });
  }

  function setWallpaperNow() {
    if (!current || current.kind === "video") return;
    var it = current;
    wallpaper.command = ["bash", "-c", '
      src="$1"; cache="$2"; key="$3"
      case "${src,,}" in
        *.heic|*.heif|*.tif|*.tiff|*.dng)
          mkdir -p "$cache/wallpaper"
          out="$cache/wallpaper/$key.jpg"
          [ -s "$out" ] || magick "$src" -auto-orient -quality 92 "$out" || { echo "Could not convert $src"; exit 0; }
          src="$out" ;;
      esac
      omarchy-theme-bg-set "$src" >/dev/null 2>&1 && echo "Wallpaper set" || echo "Could not set the wallpaper"', "_", it.path, root.cacheDir, it.id];
    wallpaper.running = true;
  }

  // `i` in the viewer: camera and file details for the current item.
  function toggleInfo() {
    infoOpen = !infoOpen;
    if (infoOpen) fetchInfo();
  }

  function fetchInfo() {
    if (!current || infoProc.running) return;
    if (infoForId === current.id) return;
    infoRows = [];
    infoProc.forId = current.id;
    infoProc.command = [root.infoScript, current.kind === "video" ? current.path : current.path];
    infoProc.running = true;
  }

  onCurrentChanged: {
    if (infoOpen && viewerOpen) fetchInfo();
    if (viewerOpen && current && current.needsOriginal && !fetching && current.id !== fetchFailedId) openViewer();
  }
  onViewerOpenChanged: {
    if (!viewerOpen) infoOpen = false;
    keys.forceActiveFocus();
  }
  onJumpOpenChanged: if (!jumpOpen) keys.forceActiveFocus()

  function copyPath() {
    withOriginals(targets(), function () { root.copyPathNow(); });
  }

  function copyPathNow() {
    var list = targets();
    if (list.length === 0) return;
    var paths = list.map(function (it) { return it.path; });
    copier.command = ["bash", "-c", 'printf "%s\n" "$@" | wl-copy', "_"].concat(paths);
    copier.running = true;
    toast.show(list.length === 1 ? "Copied " + paths[0] : "Copied " + list.length + " paths");
  }

  function startSync(from, to) {
    if (sync.running) { traceLine("sync skipped, one is already running"); return; }
    if (from && to) {
      traceLine("sync " + from + " .. " + to);
      sync.command = [root.syncScript, "--from", from, "--to", to];
    } else {
      traceLine("sync rolling");
      sync.command = [root.syncScript];
    }
    sync.running = true;
  }

  // Download originals for any thumb-only items, then run action once the
  // index points at the files that landed.
  function withOriginals(list, action) {
    var need = [];
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].needsOriginal) need.push(list[i]);
    if (need.length === 0) { action(); return; }
    if (fetching) return;
    for (var j = 0; j < need.length; j++) {
      if (!need[j].record) {
        toast.show("No iCloud id for " + need[j].name + " yet. Press r to sync, then try again.", 4000);
        return;
      }
    }
    fetching = true;
    fetchQueue = need;
    fetchAt = 0;
    fetchAction = action;
    runFetch();
  }

  function rememberOriginal(id, files) {
    function apply(list) {
      var out = [];
      for (var i = 0; i < list.length; i++) {
        if (!list[i] || list[i].id !== id) { out.push(list[i]); continue; }
        var it = Object.assign({}, list[i]);
        var still = "", movie = "";
        for (var f = 0; f < files.length; f++) {
          if (/\.(mov|mp4|m4v)$/i.test(files[f])) movie = files[f];
          else still = files[f];
        }
        if (still) it.path = still;
        if (movie && (it.kind === "video" || it.kind === "live")) {
          it.video = movie;
          if (it.kind === "video") it.path = movie;
        }
        if (still && /\.(jpe?g|png|webp|gif)$/i.test(still)) it.preview = still;
        it.needsOriginal = false;
        out.push(it);
      }
      return out;
    }
    library = apply(library);
    items = apply(items);
  }

  function runFetch() {
    var it = fetchQueue[fetchAt];
    var dest = it.path.substring(0, it.path.lastIndexOf("/"));
    fetcher.output = "";
    fetcher.command = [root.helperScript, "fetch", "--record", it.record,
      "--library", it.library || "PrimarySync", "--dest", dest, "--ts", String(it.ts)];
    fetchingId = it.id;
    if (!viewerOpen) toast.showBusy("Downloading " + it.name + "…");
    fetcher.running = true;
  }

  function fetchExited(out) {
    var res = null;
    var lines = String(out || "").trim().split("\n");
    try { res = JSON.parse(lines[lines.length - 1]); } catch (e) {}
    if (!(res && res.ok)) {
      var failed = fetchQueue[fetchAt];
      fetching = false;
      fetchingId = "";
      fetchAction = null;
      fetchQueue = [];
      fetchFailedId = failed ? failed.id : "";
      traceLine("fetch failed" + (failed ? " " + failed.name : "") + ": " + ((res && res.error) || "no answer"));
      toast.show((res && res.error) || "Could not download the original", 5000);
      return;
    }
    fetchAt++;
    var doneId = fetchQueue[fetchAt - 1] ? fetchQueue[fetchAt - 1].id : "";
    if (doneId && res.files) {
      pendingOriginal = { id: doneId, files: res.files };
      rememberOriginal(doneId, res.files);
      traceLine("fetch ok " + (res.files.length || 0) + " file(s)");
    }
    if (fetchAt < fetchQueue.length) {
      runFetch();
      return;
    }
    afterFetchId = fetchQueue[0].id;
    fetchQueue = [];
    if (reindex.running) reindexDirty = true;
    else reindex.running = true;
  }

  function finishFetch() {
    var action = fetchAction;
    var id = afterFetchId;
    var pending = pendingOriginal;
    fetchAction = null;
    afterFetchId = "";
    pendingOriginal = null;
    fetching = false;
    fetchingId = "";
    // applyIndex just reloaded whatever is on disk. Put the file we just
    // downloaded back on the open item if that reload has not caught up.
    if (pending && pending.id) rememberOriginal(pending.id, pending.files || []);
    var found = -1;
    for (var i = 0; i < items.length; i++) if (items[i].id === id) { found = i; break; }
    if (found >= 0) selected = found;
    if (found < 0) {
      traceLine("fetch finished but " + id + " is not in the grid");
      toast.show("Downloaded, but the original is not in the grid yet", 4000);
      return;
    }
    fetchFailedId = "";
    if (toast.busy) toast.opacity = 0;
    if (action) action();
  }

  function setCell(v) {
    v = Math.max(100, Math.min(400, Math.round(v)));
    if (v === settings.cell) return;
    // Remember where we were in the grid so resizing does not scroll.
    if (grid.zoomAnchor < 0) {
      var span = grid.contentHeight - grid.height;
      grid.zoomAnchor = span > 1 ? grid.contentY / span : 0;
    }
    settings.cell = v;
    settingsFile.writeAdapter();
    grid.zoomHold.restart();
  }

  function askDelete() {
    var list = targets();
    if (list.length === 0) return;
    pendingDelete = list;
  }

  function confirmDelete() {
    var list = pendingDelete;
    if (!list) return;
    pendingDelete = null;
    if (checkedCount > 0) clearChecked();
    // Fresh batch: what Undo brings back is exactly what leaves now.
    lastDeleted = [];
    batchTotal = list.length;
    batchDone = 0;
    for (var i = 0; i < list.length; i++) removeItem(list[i].id);
    var q = jobs.slice();
    for (var j = 0; j < list.length; j++) q.push({ action: "delete", item: list[j] });
    jobs = q;
    runNext();
  }

  function undoDelete() {
    // Queued deletes that have not started are simply dropped.
    var rest = [], kept = 0;
    for (var i = 0; i < jobs.length; i++) {
      if (jobs[i].action === "delete") { insertItem(jobs[i].item); kept++; }
      else rest.push(jobs[i]);
    }
    if (kept > 0) { jobs = rest; batchTotal -= kept; }
    // One in flight gets its restore right behind it.
    if (trashBusy && trash.action === "delete") {
      undoAfterCurrent = true;
      toast.showBusy("Deleting " + trash.subject.name + "…  undo queued");
      return;
    }
    // Everything that already went comes back.
    var back = lastDeleted;
    lastDeleted = [];
    for (var j = 0; j < back.length; j++) enqueue({ action: "restore", item: back[j] });
    if (back.length === 0 && kept > 0) toast.show(kept === 1 ? "Kept " + rest.length : "Kept " + kept + " items");
  }

  function enqueue(job) {
    var q = jobs.slice(); q.push(job); jobs = q;
    runNext();
  }

  function runNext() {
    if (trash.running || jobs.length === 0) return;
    var q = jobs.slice();
    var job = q.shift();
    jobs = q;
    var it = job.item;
    trashBusy = true;
    trash.action = job.action;
    trash.subject = it;
    if (job.action === "delete") {
      var cmd = [root.helperScript, "delete", "--key", it.id, "--file", it.path, "--ts", String(it.ts)];
      if (it.kind === "live" && it.video) cmd.push("--companion", it.video);
      if (it.record) cmd.push("--record", it.record);
      if (it.library) cmd.push("--library", it.library);
      if (it.shared) cmd.push("--shared");
      trash.command = cmd;
      toast.showBusy(batchTotal > 1 ? "Deleting " + (batchDone + 1) + " of " + batchTotal + "…" : "Deleting " + it.name + "…");
    } else {
      trash.command = [root.helperScript, "restore", "--key", it.id];
      toast.showBusy("Restoring " + it.name + "…");
    }
    trash.running = true;
  }

  function trashFinished(action, it, out) {
    trashBusy = false;
    var res = null;
    var lines = String(out || "").trim().split("\n");
    try { res = JSON.parse(lines[lines.length - 1]); } catch (e) {}
    var ok = res && res.ok;
    var moreDeletes = jobs.some(function (j) { return j.action === "delete"; });
    if (action === "delete") {
      batchDone++;
      if (ok) {
        var l = lastDeleted.slice(); l.push(it); lastDeleted = l;
        if (undoAfterCurrent) {
          undoAfterCurrent = false;
          undoDelete();
        } else if (!moreDeletes) {
          toast.showUndo(lastDeleted.length === 1
            ? "Moved " + it.name + " to Recently Deleted"
            : "Moved " + lastDeleted.length + " items to Recently Deleted");
        }
      } else {
        undoAfterCurrent = false;
        insertItem(it);
        toast.show("Could not delete " + it.name + ": " + ((res && res.error) || "no answer from the helper"), 8000);
      }
    } else {
      if (ok) {
        insertItem(it);
        if (!jobs.some(function (j) { return j.action === "restore"; })) toast.show("Restored");
      } else {
        var l2 = lastDeleted.slice(); l2.push(it); lastDeleted = l2;
        toast.show("Could not restore " + it.name + ": " + ((res && res.error) || "no answer from the helper"), 8000);
      }
    }
    if (reindex.running) reindexDirty = true; else reindex.running = true;
    runNext();
  }

  function removeItem(id) {
    var lib = library.slice();
    for (var n = 0; n < lib.length; n++) if (lib[n].id === id) { lib.splice(n, 1); break; }
    library = lib;
    var list = items.slice();
    var idx = -1;
    for (var i = 0; i < list.length; i++) if (list[i].id === id) { idx = i; break; }
    if (idx < 0) return;
    list.splice(idx, 1);
    var keepSel = Math.min(idx, list.length - 1);
    rebuild(list, keepSel);
  }

  function insertItem(it) {
    var lib = library.slice();
    var libPos = lib.length;
    for (var n = 0; n < lib.length; n++) if (lib[n].ts > it.ts) { libPos = n; break; }
    lib.splice(libPos, 0, it);
    library = lib;
    if (dateFilter && String(it.date).indexOf(dateFilter) !== 0) return;
    var list = items.slice();
    var pos = list.length;
    for (var i = 0; i < list.length; i++) if (list[i].ts > it.ts) { pos = i; break; }
    list.splice(pos, 0, it);
    rebuild(list, pos);
  }

  // Swap in a new list without the view moving: the Repeater re-creates
  // every delegate, so the scroll position is captured first and pinned
  // again while the new content height settles.
  function rebuild(list, sel) {
    var y = grid.contentY;
    suppressReveal = true;
    grid.restoreY = (loadingOlder || pinBottom) ? -1 : y;
    items = list;
    days = groupDays(list);
    selected = list.length > 0 ? Math.max(0, Math.min(sel, list.length - 1)) : -1;
    if (selected < 0) viewerOpen = false;
    if (checkedCount > 0) {
      var map = {};
      for (var i = 0; i < list.length; i++) if (checked[list[i].id]) map[list[i].id] = true;
      setChecked(map);
    }
    if (loadingOlder) {
      // Content height catches up after the delegates land; that handler
      // shifts contentY by however much was prepended.
    } else if (pinBottom) grid.scrollToBottom();
    else grid.contentY = grid.clampY(y);
    settleTimer.restart();
  }

  // The tour, for the demo clip: scroll down with a bit of pace, open a
  // Live Photo and let it play, show the details, then back to the grid for
  // a delete and its undo. About twenty seconds.
  Timer {
    id: tourKickoff
    interval: 1500
    onTriggered: { root.tourStarted = true; tour.start(); }
  }
  SequentialAnimation {
    id: tour
    NumberAnimation {
      target: grid; property: "contentY"
      from: 0; to: Math.max(0, grid.contentHeight - grid.height)
      duration: 4500; easing.type: Easing.InOutCubic
    }
    PauseAnimation { duration: 600 }
    ScriptAction { script: {
      var last = -1;
      for (var i = root.items.length - 1; i >= 0; i--) if (root.items[i].kind === "live") { last = i; break; }
      root.jumpTo(last >= 0 ? last : root.items.length - 1, false);
    } }
    PauseAnimation { duration: 700 }
    ScriptAction { script: root.viewerOpen = true }
    PauseAnimation { duration: 1200 }
    ScriptAction { script: viewer.playLive() }
    PauseAnimation { duration: 2600 }
    ScriptAction { script: root.toggleInfo() }
    PauseAnimation { duration: 3000 }
    ScriptAction { script: root.infoOpen = false }
    PauseAnimation { duration: 500 }
    ScriptAction { script: root.viewerOpen = false }
    PauseAnimation { duration: 900 }
    ScriptAction { script: root.askDelete() }
    PauseAnimation { duration: 2000 }
    ScriptAction { script: root.confirmDelete() }
    PauseAnimation { duration: 2200 }
    ScriptAction { script: root.undoDelete() }
    PauseAnimation { duration: 2000 }
    // A range selection, then the keys overlay.
    ScriptAction { script: {
      var n = root.items.length;
      root.jumpTo(Math.max(0, n - 9), false);
      root.jumpTo(Math.max(0, n - 4), true);
    } }
    PauseAnimation { duration: 2200 }
    ScriptAction { script: { root.clearChecked(); root.helpOpen = true; } }
    PauseAnimation { duration: 2600 }
    ScriptAction { script: root.helpOpen = false }
    PauseAnimation { duration: 800 }
  }

  Timer {
    id: settleTimer
    interval: 150
    onTriggered: { root.suppressReveal = false; grid.restoreY = -1; }
  }

  FloatingWindow {
    id: win
    visible: true
    // A suffix from the environment lets a window rule single out a capture
    // instance (see omarchy-icloud-photos --demo --tour).
    title: "Omarchy iCloud Photos" + (Quickshell.env("OMARCHY_ICLOUD_PHOTOS_TITLE_SUFFIX") || "")
    implicitWidth: 1180
    implicitHeight: 800
    color: appTheme.background

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Component.onCompleted: forceActiveFocus()
      // While the date field is up, it sees the key first. Anything it does
      // not take (arrows, shortcuts) stops here so the grid stays put.
      Keys.forwardTo: root.jumpOpen ? [jumpOverlay.input] : []

      Keys.onReleased: event => { if (event.key === Qt.Key_Control) root.ctrlHeld = false; }
      Keys.onPressed: event => {
        var k = event.key;
        var t = event.text;
        if (k === Qt.Key_Control) { root.ctrlHeld = true; return; }
        if (root.needLogin) return;
        // The open photo wins over the grid, including when another field
        // still thinks it has the keyboard.
        if (root.viewerOpen && (k === Qt.Key_Escape || k === Qt.Key_Backspace)) {
          root.viewerOpen = false;
          keys.forceActiveFocus();
          event.accepted = true;
          return;
        }
        if (root.helpOpen) {
          if (t === "?" || k === Qt.Key_Escape || t === "q") root.helpOpen = false;
          event.accepted = true;
          return;
        }
        if (root.jumpOpen) {
          if (k === Qt.Key_Escape) root.jumpOpen = false;
          event.accepted = true;
          return;
        }
        if (t === "?") { root.helpOpen = true; event.accepted = true; return; }
        if (root.pendingDelete) {
          if (k === Qt.Key_Escape || t === "n") root.pendingDelete = null
          else if (k === Qt.Key_Return || k === Qt.Key_Enter || t === "y") root.confirmDelete()
          event.accepted = true;
          return;
        }
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (t === "d") { root.askDelete(); event.accepted = true; return; }
        if (t === "u") { root.undoDelete(); event.accepted = true; return; }
        if (t === "s") { root.saveToDownloads(); event.accepted = true; return; }
        if (t === "W") { root.setWallpaper(); event.accepted = true; return; }
        if (ctrl && k === Qt.Key_A) { root.checkAll(); event.accepted = true; return; }
        // x, or ctrl+space, ticks the item under the cursor like a ctrl-click.
        if ((t === "x" || (ctrl && k === Qt.Key_Space)) && !root.viewerOpen) {
          if (root.selected >= 0) { root.pinBottom = false; root.toggleChecked(root.selected); }
          event.accepted = true; return;
        }
        if (root.viewerOpen) {
          if (t === "i") root.toggleInfo()
          else if ((k === Qt.Key_Escape || t === "q") && root.infoOpen) root.infoOpen = false
          else if (k === Qt.Key_Escape || t === "q" || k === Qt.Key_Backspace) root.viewerOpen = false
          // Arrows scrub while a video is on screen; h/l always move on.
          else if (k === Qt.Key_Left && viewer.videoShown) viewer.seekBy(-5000)
          else if (k === Qt.Key_Right && viewer.videoShown) viewer.seekBy(5000)
          else if (k === Qt.Key_Left || t === "h" || t === "k" || k === Qt.Key_Up) root.move(-1)
          else if (k === Qt.Key_Right || t === "l" || t === "j" || k === Qt.Key_Down) root.move(1)
          else if (k === Qt.Key_Space) viewer.togglePlay()
          else if (t === "o") root.openCurrent()
          else if (t === "y") root.copyCurrent()
          else if (t === "Y") root.copyPath()
          else return;
          event.accepted = true;
          return;
        }
        if (t === "q") Qt.quit()
        else if (k === Qt.Key_Escape) { if (root.checkedCount > 0) root.clearChecked(); else if (root.dateFilter) root.setDateFilter(""); }
        else if (k === Qt.Key_Left || k === Qt.Key_H) root.move(-1, shift)
        else if (k === Qt.Key_Right || k === Qt.Key_L) root.move(1, shift)
        else if (k === Qt.Key_Down || k === Qt.Key_J) { root.noteOlderDown(root.cell); root.move(grid.columns, shift); }
        else if (k === Qt.Key_Up || k === Qt.Key_K) {
          var rowAtStart = root.selected === 0;
          root.move(-grid.columns, shift);
          if (rowAtStart && root.selected === 0 && !shift) root.maybeLoadOlder();
        }
        else if (k === Qt.Key_PageDown) { root.noteOlderDown(grid.height); root.move(grid.pageStep(), shift); }
        else if (k === Qt.Key_PageUp) {
          var pageAtStart = root.selected === 0;
          root.move(-grid.pageStep(), shift);
          if (pageAtStart && root.selected === 0) root.maybeLoadOlder();
        }
        else if (t === "g") { root.jumpTo(root.items.length > 0 ? 0 : -1, false); }
        else if (t === "G") { root.jumpTo(root.items.length - 1, false); root.pinBottom = true; grid.scrollToBottom(); }
        else if (t === "/") { root.jumpOpen = true; }
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) { if (root.current) root.openViewer(); }
        else if (t === "o") root.openCurrent()
        else if (t === "y") root.copyCurrent()
        else if (t === "Y") root.copyPath()
        else if (t === "r") root.startSync()
        else if (t === "-" || t === "_") root.setCell(root.cell - 24)
        else if (t === "+" || t === "=") root.setCell(root.cell + 24)
        else return;
        event.accepted = true;
      }

      // ---- Header ---------------------------------------------------------
      Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        color: appTheme.darkBackground

        Row {
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 14
          Text {
            text: "Omarchy iCloud Photos"
            color: appTheme.brightForeground
            font.family: appTheme.fontFamily
            font.pixelSize: 17
            font.bold: true
          }
          Text {
            anchors.baseline: parent.children[0].baseline
            text: root.dateFilter ? root.filterLabel() : root.rangeLabel()
            color: root.dateFilter ? appTheme.accent : appTheme.foreground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
          }
          Text {
            anchors.baseline: parent.children[0].baseline
            visible: root.dateFilter !== ""
            text: "esc shows all"
            color: filterClear.containsMouse ? appTheme.brightForeground : appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
            MouseArea {
              id: filterClear
              anchors.fill: parent
              anchors.margins: -4
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setDateFilter("")
            }
          }
          Text {
            anchors.baseline: parent.children[0].baseline
            text: root.dateFilter && root.library.length
                  ? root.items.length + " of " + root.library.length
                  : (root.items.length > 0 ? root.items.length + " items" : "")
            color: appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: 12
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.syncedLabel()
            color: root.busy ? appTheme.accent : appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 1
          }
          Rectangle {
            width: 34; height: 34; radius: 6
            color: refreshArea.containsMouse ? appTheme.lighterBackground : "transparent"
            Text {
              anchors.centerIn: parent
              text: ""
              color: root.busy ? appTheme.accent : appTheme.foreground
              font.family: appTheme.fontFamily
              font.pixelSize: 15
              RotationAnimation on rotation {
                running: root.busy; loops: Animation.Infinite; from: 0; to: 360; duration: 1400
              }
            }
            MouseArea {
              id: refreshArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.startSync()
            }
          }
        }
      }

      // ---- Problem banner -------------------------------------------------
      Rectangle {
        id: banner
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        visible: root.status.state === "error"
        height: visible ? bannerText.implicitHeight + 20 : 0
        color: Qt.rgba(appTheme.red.r, appTheme.red.g, appTheme.red.b, 0.18)
        Text {
          id: bannerText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: 20
          anchors.verticalCenter: parent.verticalCenter
          text: root.status.message
          wrapMode: Text.Wrap
          color: appTheme.brightForeground
          font.family: appTheme.fontFamily
          font.pixelSize: appTheme.fontSize - 1
        }
      }

      // ---- Grid -----------------------------------------------------------
      Flickable {
        id: grid
        anchors.top: banner.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight + 32
        boundsBehavior: Flickable.StopAtBounds
        // Dragging the grid used to pan and flick. Wheel and touchpad still
        // scroll, by moving the content directly so there is no inertia.
        interactive: false
        ScrollBar.vertical: ScrollBar {
          id: gridBar
          policy: ScrollBar.AlwaysOn
          visible: grid.contentHeight > grid.height + 1
          width: 10
          contentItem: Rectangle {
            implicitWidth: 6
            radius: 3
            color: gridBar.pressed ? appTheme.brightForeground : appTheme.muted
          }
          background: Item { implicitWidth: 8 }
          onPressedChanged: {
            if (pressed) { root.pinBottom = false; root.olderBarY = grid.contentY; }
          }
          onPositionChanged: {
            if (!pressed) return;
            var y = grid.contentY;
            if (root.olderBarY >= 0 && y > root.olderBarY) root.noteOlderDown(y - root.olderBarY);
            root.olderBarY = y;
            if (y < grid.height) root.maybeLoadOlder();
          }
        }
        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          blocking: true
          onWheel: event => {
            var ctrl = root.ctrlHeld || (event.modifiers & Qt.ControlModifier) !== 0;
            if (ctrl) {
              var steps = event.angleDelta.y !== 0 ? event.angleDelta.y / 120 : event.pixelDelta.y / 40;
              if (steps !== 0) root.setCell(root.cell + steps * 16);
              event.accepted = true;
              return;
            }
            var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 140;
            var next = grid.contentY - dy;
            // dy > 0 scrolls toward older photos. A downward move rearms
            // the next fetch; ups while one is running are ignored.
            if (dy < 0) root.noteOlderDown(-dy);
            else if (dy > 0 && next < grid.height) root.maybeLoadOlder();
            grid.contentY = Math.max(0, Math.min(grid.contentHeight - grid.height, next));
            root.pinBottom = false;
            event.accepted = true;
          }
        }

        readonly property int columns: Math.max(1, Math.floor((width - 40 + root.gap) / (root.cell + root.gap)))
        function pageStep() {
          var rows = Math.max(1, Math.floor(height / (root.cell + root.gap)));
          return rows * columns;
        }

        // Scroll position to hold while a rebuild changes the content height.
        property real restoreY: -1
        // Fraction of the scroll range to hold while thumbnails are resizing.
        property real zoomAnchor: -1
        Timer {
          id: zoomHold
          interval: 150
          onTriggered: grid.zoomAnchor = -1
        }

        function clampY(y) { return Math.max(0, Math.min(contentHeight - height, y)); }
        function scrollToBottom() {
          contentY = Math.max(0, contentHeight - height);
        }
        onContentHeightChanged: {
          if (zoomAnchor >= 0) {
            contentY = clampY(zoomAnchor * Math.max(0, contentHeight - height));
            zoomHold.restart();
            return;
          }
          if (root.loadingOlder && root.olderBaseH >= 0) {
            var added = contentHeight - root.olderBaseH;
            contentY = clampY(root.olderBaseY + Math.max(0, added));
          } else if (root.pinBottom) scrollToBottom();
          else if (restoreY >= 0) contentY = clampY(restoreY);
        }
        onHeightChanged: if (root.pinBottom) scrollToBottom()
        onMovementStarted: root.pinBottom = false

        function reveal(thumb) {
          if (root.pinBottom || root.suppressReveal || root.loadingOlder || zoomAnchor >= 0) return;
          var p = thumb.mapToItem(grid.contentItem, 0, 0);
          var top = p.y - 44;      // keep the day label in view when moving up
          var bottom = p.y + thumb.height + 16;
          if (top < contentY) contentY = Math.max(0, top);
          else if (bottom > contentY + height) contentY = Math.min(contentHeight - height, bottom - height);
        }

        Column {
          id: column
          x: 20
          y: 16
          width: grid.width - 40
          spacing: 22

          // Reserved so the spinner can appear above the oldest day without
          // shifting the grid when a week starts or finishes loading.
          Item {
            width: parent.width
            height: 36
            Text {
              anchors.centerIn: parent
              visible: root.showOlderSpinner
              text: "\uf110"
              color: appTheme.accent
              font.family: appTheme.fontFamily
              font.pixelSize: 18
              RotationAnimation on rotation {
                running: root.showOlderSpinner
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
              }
            }
          }

          Repeater {
            model: root.days
            delegate: Column {
              required property var modelData
              width: column.width
              spacing: 10

              Item {
                width: dayRow.implicitWidth
                height: dayRow.implicitHeight
                Row {
                  id: dayRow
                  spacing: 8
                  Text {
                    id: dayTitle
                    text: modelData.label
                    color: dayHit.containsMouse ? appTheme.accent : appTheme.brightForeground
                    font.family: appTheme.fontFamily
                    font.pixelSize: appTheme.fontSize + 1
                    font.bold: true
                  }
                  Text {
                    anchors.baseline: dayTitle.baseline
                    text: modelData.indices.length
                    color: appTheme.darkForeground
                    font.family: appTheme.fontFamily
                    font.pixelSize: appTheme.fontSize
                  }
                }
                MouseArea {
                  id: dayHit
                  anchors.fill: parent
                  anchors.margins: -6
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.jumpOpen = true
                }
              }

              Flow {
                width: parent.width
                spacing: root.gap
                Repeater {
                  model: modelData.indices
                  delegate: Thumb {
                    required property int modelData
                    index: modelData
                    item: root.items[modelData]
                    theme: appTheme
                    size: root.cell
                    selected: root.selected === modelData
                    // items[] can be a step behind the model while a delete
                    // rebuilds the grid, hence the guard.
                    checked: !!root.items[modelData] && root.checked[root.items[modelData].id] === true
                    onSelectedChanged: if (selected) grid.reveal(this)
                    // Click selects, a click on the selected one opens.
                    // Shift-click checks the range from the anchor, ctrl-click
                    // toggles one.
                    onClicked: modifiers => {
                      root.pinBottom = false;
                      if (modifiers & Qt.ShiftModifier) root.jumpTo(index, true);
                      else if (modifiers & Qt.ControlModifier) { root.selected = index; root.toggleChecked(index); }
                      else if (root.selected === index && root.checkedCount === 0) root.openViewer();
                      else root.jumpTo(index, false);
                    }
                  }
                }
              }
            }
          }
        }

      }

      // Empty / first-run state. A sibling of the grid rather than a child:
      // children of a Flickable live in its content item, which is only as
      // tall as the content, so "centered" would sit at the top.
      Column {
        anchors.centerIn: grid
        spacing: 10
        visible: root.items.length === 0 && !root.needLogin
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.busy ? "First sync…" : (root.indexMissing ? "Nothing synced yet" : "No photos in the " + root.rangeLabel().replace("last ", "last "))
          color: appTheme.foreground
          font.family: appTheme.fontFamily
          font.pixelSize: 16
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.busy ? "This can take a few minutes" : "Press r to sync, ? for the keys"
          color: appTheme.darkForeground
          font.family: appTheme.fontFamily
          font.pixelSize: appTheme.fontSize
        }
      }

      // ---- Footer ---------------------------------------------------------
      Rectangle {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34
        color: appTheme.darkBackground
        // The filename is a button: click copies the full path.
        Row {
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 12
          Text {
            id: footerName
            anchors.verticalCenter: parent.verticalCenter
            text: root.checkedCount > 1 ? root.checkedCount + " selected" : (root.current ? root.current.name : "")
            color: root.checkedCount > 1 ? appTheme.accent : (nameArea.containsMouse ? appTheme.brightForeground : appTheme.darkForeground)
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 1
            font.underline: nameArea.containsMouse
            MouseArea {
              id: nameArea
              anchors.fill: parent
              anchors.margins: -4
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.copyPath()
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.checkedCount > 1 ? "esc clears" : (root.current ? root.current.time : "")
            color: appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 1
          }
        }
        Row {
          anchors.right: parent.right
          anchors.rightMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 18
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 24; height: 24; radius: 5
            color: helpArea.containsMouse ? appTheme.lighterBackground : "transparent"
            Text {
              anchors.centerIn: parent
              text: "?"
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
              font.bold: true
            }
            MouseArea {
              id: helpArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.helpOpen = !root.helpOpen
            }
          }
          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf03e"
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: 9
            }
            Slider {
              id: zoom
              anchors.verticalCenter: parent.verticalCenter
              width: 140
              from: 100
              to: 400
              stepSize: 4
              value: root.cell
              onMoved: root.setCell(value)
              background: Rectangle {
                x: zoom.leftPadding
                y: zoom.topPadding + zoom.availableHeight / 2 - height / 2
                width: zoom.availableWidth
                height: 3
                radius: 2
                color: appTheme.lighterBackground
                Rectangle {
                  width: zoom.visualPosition * parent.width
                  height: parent.height
                  radius: 2
                  color: appTheme.accent
                }
              }
              handle: Rectangle {
                x: zoom.leftPadding + zoom.visualPosition * (zoom.availableWidth - width)
                y: zoom.topPadding + zoom.availableHeight / 2 - height / 2
                width: 12; height: 12; radius: 6
                color: zoom.pressed ? appTheme.brightForeground : appTheme.foreground
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf03e"
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: 14
            }
          }
        }
      }

      // ---- Viewer overlay -------------------------------------------------
      Viewer {
        id: viewer
        anchors.fill: parent
        theme: appTheme
        item: root.viewerOpen ? root.current : null
        infoOpen: root.infoOpen
        infoRows: (root.current && root.infoForId === root.current.id) ? root.infoRows : []
        fetching: root.current && root.fetchingId !== "" && root.fetchingId === root.current.id
        onRequestInfo: root.toggleInfo()
        onRequestNext: root.move(1)
        onRequestPrev: root.move(-1)
        onRequestCopyPath: root.copyPath()
        onRequestSave: root.saveToDownloads()
        onRequestClose: root.viewerOpen = false
      }

      // ---- Sign-in ----------------------------------------------------------
      Rectangle {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        visible: root.needLogin
        color: appTheme.background
        MouseArea { anchors.fill: parent; hoverEnabled: true }
        Login {
          id: loginCard
          anchors.fill: parent
          theme: appTheme
          username: root.appleId
          onSubmitCredentials: (u, p) => root.startLogin(u, p)
          onSubmitCode: code => login.write(code + "\n")
        }
      }

      // ---- Delete dialog --------------------------------------------------
      ConfirmDelete {
        anchors.fill: parent
        theme: appTheme
        items: root.pendingDelete
        onConfirmed: root.confirmDelete()
        onCancelled: root.pendingDelete = null
      }

      // ---- Date jump --------------------------------------------------------
      Jump {
        id: jumpOverlay
        anchors.fill: parent
        theme: appTheme
        visible: root.jumpOpen
        days: root.dayChoices()
        onRequestClose: root.jumpOpen = false
        onPickDay: date => root.pickDay(date)
        onSubmitDate: text => root.goToDate(text)
      }

      // ---- Help -------------------------------------------------------------
      Help {
        anchors.fill: parent
        theme: appTheme
        visible: root.helpOpen
        onRequestClose: root.helpOpen = false
      }

      // ---- Toast, with an Undo button after a delete ----------------------
      Rectangle {
        id: toast
        property string message: ""
        property bool undo: false
        property bool busy: false
        function show(m, ms) { message = m; undo = false; busy = false; opacity = 1; hide.interval = ms || 1600; hide.restart(); }
        function showUndo(m) { message = m; undo = true; busy = false; opacity = 1; hide.interval = 12000; hide.restart(); }
        function showBusy(m) { message = m; undo = false; busy = true; opacity = 1; hide.stop(); }
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 56
        width: toastRow.implicitWidth + 32
        height: 40
        radius: 8
        color: appTheme.lighterBackground
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Row {
          id: toastRow
          anchors.centerIn: parent
          spacing: 16
          Text {
            visible: toast.busy
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf021"
            color: appTheme.accent
            font.family: appTheme.fontFamily
            font.pixelSize: 13
            RotationAnimation on rotation {
              running: toast.busy; loops: Animation.Infinite; from: 0; to: 360; duration: 1400
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: toast.message
            color: appTheme.brightForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
          }
          Rectangle {
            visible: toast.undo
            anchors.verticalCenter: parent.verticalCenter
            width: undoText.implicitWidth + 20
            height: 26
            radius: 5
            color: undoArea.containsMouse ? Qt.lighter(appTheme.accent, 1.1) : appTheme.accent
            Text {
              id: undoText
              anchors.centerIn: parent
              text: "Undo  u"
              color: appTheme.darkerBackground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
              font.bold: true
            }
            MouseArea {
              id: undoArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.undoDelete()
            }
          }
        }
        Timer { id: hide; interval: 1600; onTriggered: toast.opacity = 0 }
      }
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Themes.js" as Themes

// Live network traffic monitor: speed gauges + history graph, an active
// connections list with country lookups, and LAN device discovery. No
// firewall or blocking here -- read-only visibility only.
Panel {
  id: root
  moduleName: "io.github.cjohnson46.omaglass"
  ipcTarget: "io.github.cjohnson46.omaglass"
  // Own our single IpcHandler explicitly rather than relying on the base's
  // generic one (see omarchy.network for the same pattern).
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    root.controller.show()
    refresh()
  }
  function close() {
    root.controller.hide()
  }
  function toggle() {
    root.opened ? close() : open()
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- navigation ------------------------------------------------------------

  property string activeTab: "traffic"
  property string previousTab: "traffic"

  function openSettings() {
    if (activeTab !== "settings") {
      previousTab = activeTab
      activeTab = "settings"
    } else {
      activeTab = previousTab
    }
  }

  // ---- live traffic sampling --------------------------------------------------

  readonly property int historyMax: 1800

  property var downHistory: []
  property var upHistory: []
  // Parallel to downHistory/upHistory (same push/shift, same length,
  // always) -- the wall-clock time each entry was actually sampled at. See
  // resampleByTime() below for why this exists.
  property var sampleTimes: []
  property real downRate: 0
  property real upRate: 0
  property real peakDown: 0
  property real peakUp: 0
  property real sessionDown: 0
  property real sessionUp: 0
  property string iface: ""
  property string ifaceType: ""
  property string ssid: ""

  // Starts out equal to the persisted default (see defaultHistoryWindowSeconds
  // below, near the rest of the saved settings) -- this is a plain
  // initializer, not a permanent binding, so clicking a window button in
  // the Traffic tab still freely overrides it for just the current session
  // without touching the saved default.
  property int historyWindowSeconds: defaultHistoryWindowSeconds

  // Resamples (times, values) onto exactly `outputPoints`, evenly spaced
  // across the last `windowSeconds` of real wall-clock time, holding each
  // point at the most recent real sample at or before it (zero before any
  // real data existed yet, e.g. the first minutes of a session or a window
  // longer than the session so far).
  //
  // This is deliberately NOT "the last N raw array entries": background
  // sampling backs off from 1s to 4s while the popup is closed to save
  // CPU/process-spawn overhead (see samplingIntervalMs below) -- a plain
  // slice-the-last-N-samples window quietly represented anywhere from 2 to
  // 8 real minutes depending on how much of that time the popup happened
  // to be closed, so reopening after being away for a couple of minutes
  // looked like the graph had "barely moved" even though sampling never
  // actually stopped -- most of the visible window was still old,
  // pre-close data. Resampling by actual elapsed time keeps "2m" meaning
  // the last 2 real minutes regardless of how the sampling rate varied
  // getting there, at the cost of a flat/held stretch during any span that
  // was genuinely only sampled coarsely -- an honest gap, not invented
  // motion.
  //
  // A fixed `outputPoints` (rather than however many raw samples exist)
  // is what keeps the graph's pixel spacing constant frame to frame --
  // see BandwidthGraph.qml for what a shifting point count used to do to
  // the scroll.
  //
  // Every output point is a fixed-width time bucket aligned to absolute
  // wall-clock time (Unix-epoch-relative multiples of the bucket width),
  // NOT "N buckets back from `Date.now()`". That distinction matters: an
  // earlier version anchored the whole grid to a freshly-read `Date.now()`
  // on every recompute, so two recomputes even a few hundred milliseconds
  // apart -- which happens constantly, since this recomputes on every new
  // sample and Quickshell's own render/property-evaluation timing isn't
  // synchronized to the sampling interval -- landed their grid points at
  // very slightly different absolute times. A grid point sitting right at
  // a step-function boundary between two real samples could flip which
  // side it read from between one recompute and the next, which is what
  // made already-drawn peaks visibly reshape and creep left/right as the
  // graph scrolled, not just the still-live newest edge. Bucketing by
  // fixed absolute-time boundaries instead means a given point in time
  // always falls in the same bucket no matter when the resample runs, so
  // once a bucket is fully in the past its value is permanent -- verified
  // directly: resampled the same underlying data at ~150 recompute times
  // spread unevenly across a 5-second span and confirmed zero of the
  // settled (non-newest-edge) buckets ever changed value.
  // `overscan` (optional) extends the returned array with that many EXTRA
  // buckets immediately BEFORE the window, same fixed epoch-aligned grid,
  // prepended in chronological order. Omit it (or pass 0) for the original
  // exactly-`outputPoints` behavior. See graphOverscanPoints below for why
  // these extra buckets exist.
  function resampleByTime(times, values, windowSeconds, outputPoints, overscan) {
    var extra = overscan || 0
    var total = outputPoints + extra
    var out = new Array(total)
    if (times.length === 0) {
      for (var z = 0; z < total; z++) out[z] = 0
      return out
    }
    var stepMs = (windowSeconds * 1000) / Math.max(1, outputPoints - 1)
    var currentSlot = Math.floor(Date.now() / stepMs)
    var idx = 0
    var n = times.length
    for (var i = 0; i < total; i++) {
      var slot = currentSlot - (total - 1) + i
      var slotEndMs = (slot + 1) * stepMs
      while (idx < n - 1 && times[idx + 1] < slotEndMs) idx++
      out[i] = times[idx] < slotEndMs ? values[idx] : 0
    }
    return out
  }

  // How many real buckets before the visible window BandwidthGraph gets to
  // see, purely so it always has a genuine left-hand neighbor to spline
  // against. Without this, the bucket that's about to become the leftmost
  // VISIBLE point is, right up until that tick, an interior point (tangent
  // averaged with neighbors on both sides); the instant the window slides
  // and it becomes the new endpoint, its tangent is recomputed from only
  // its right-hand neighbor -- a real, correct change in the curve fit, but
  // one that visibly reshapes/kinks the line right at the left edge every
  // tick as points age out of view. Feeding a few real trailing buckets in
  // as permanent off-canvas neighbors keeps that point's spline math
  // interior-style always, so nothing about its rendered shape changes
  // right as it crosses the edge -- same buckets also double as the
  // scroll-compensation scaffold in BandwidthGraph (see its own
  // overscanPoints/pending-offset comments). Small and fixed regardless of
  // window length, so this stays cheap even at the 30-minute window.
  readonly property int graphOverscanPoints: 4

  // How many grid slots (see resampleByTime above) the window has actually
  // advanced by since the last real sample, for WAN and LAN respectively.
  // Real sample arrivals aren't perfectly spaced -- e.g. two samples landing
  // just inside the same time bucket advance the window by 0 slots, or a
  // slow tick that straddles a bucket boundary can advance it by 2+ -- so
  // this can be anything from 0 upward, not always 1. BandwidthGraph's
  // scroll animation used to hardcode an assumption of exactly 1 slot per
  // tick, which produced a visible snap left or right whenever the real
  // shift didn't match that assumption; it now reads this instead. Computed
  // here, inside the same imperative tick that bumps syncTick/lanSyncTick,
  // rather than as a property binding, so it's a plain one-shot measurement
  // with no re-entrancy risk.
  property int lastWanSlot: -1
  property int lastLanSlot: -1
  property int wanSlotShift: 1
  property int lanSlotShift: 1

  function slotFor(nowMs, windowSeconds, outputPoints) {
    var stepMs = (windowSeconds * 1000) / Math.max(1, outputPoints - 1)
    return Math.floor(nowMs / stepMs)
  }

  // A window-size change (user picks a different Traffic-tab button)
  // redefines what a "slot" even is (different stepMs), so any
  // previously-tracked slot number is meaningless against the new grid --
  // reset rather than let it produce a bogus giant jump.
  onHistoryWindowSecondsChanged: {
    root.lastWanSlot = -1
    root.lastLanSlot = -1
  }

  readonly property var windowedDownHistoryFull: resampleByTime(sampleTimes, downHistory, historyWindowSeconds, historyWindowSeconds, graphOverscanPoints)
  readonly property var windowedUpHistoryFull: resampleByTime(sampleTimes, upHistory, historyWindowSeconds, historyWindowSeconds, graphOverscanPoints)
  // Unchanged shape/semantics for every existing consumer (hover-tooltip
  // value lookups included) -- exactly `historyWindowSeconds` points, same
  // as before graphOverscanPoints existed.
  readonly property var windowedDownHistory: windowedDownHistoryFull.slice(graphOverscanPoints)
  readonly property var windowedUpHistory: windowedUpHistoryFull.slice(graphOverscanPoints)
  readonly property var windowedDownOverscan: windowedDownHistoryFull.slice(0, graphOverscanPoints)
  readonly property var windowedUpOverscan: windowedUpHistoryFull.slice(0, graphOverscanPoints)

  // The small bar-icon graph makes no "last N real seconds" promise the
  // way the labeled Traffic-tab windows do -- it's just "recent activity
  // at a glance" -- so it keeps the simpler last-N-raw-samples behavior,
  // zero-padded until that many samples exist.
  function lastNRaw(values, n) {
    var raw = values.slice(Math.max(0, values.length - n))
    if (raw.length >= n) return raw
    var padded = new Array(n - raw.length)
    for (var i = 0; i < padded.length; i++) padded[i] = 0
    return padded.concat(raw)
  }
  readonly property int barHistoryPoints: 40
  readonly property var barDownHistory: lastNRaw(downHistory, barHistoryPoints)
  readonly property var barUpHistory: lastNRaw(upHistory, barHistoryPoints)

  property real prevRxBytes: -1
  property real prevTxBytes: -1
  property real prevSampleTime: 0
  property string prevIface: ""

  readonly property string downRateText: Model.formatRate(downRate)
  readonly property string upRateText: Model.formatRate(upRate)
  readonly property string peakDownText: Model.formatRate(peakDown)
  readonly property string peakUpText: Model.formatRate(peakUp)
  readonly property string sessionDownText: Model.formatBytes(sessionDown)
  readonly property string sessionUpText: Model.formatBytes(sessionUp)

  readonly property string connectionLabel: {
    if (root.iface === "") return "No connection"
    var kind = root.ifaceType === "wifi" ? "Wi-Fi"
      : (root.ifaceType === "ethernet" ? "Ethernet" : (root.ifaceType || "Network"))
    var extra = root.ssid !== "" ? (" · " + root.ssid) : ""
    return kind + extra + " · " + root.iface
  }

  function refresh() {
    statusProc.running = true
    lanStatsProc.running = true
    if (root.opened) {
      refreshConnections()
      refreshDevices()
    }
  }

  function sample(text) {
    var info = Model.parseStatus(text)
    var rx = Model.toNumber(info.rx_bytes, -1)
    var tx = Model.toNumber(info.tx_bytes, -1)
    var now = Date.now()
    var currentIface = info.iface || ""

    root.iface = currentIface
    root.ifaceType = info.type || ""
    root.ssid = info.ssid || ""

    if (rx < 0 || tx < 0 || currentIface === "") {
      pushSample(0, 0)
      prevRxBytes = -1
      prevTxBytes = -1
      return
    }

    if (prevRxBytes >= 0 && prevIface === currentIface && rx >= prevRxBytes && tx >= prevTxBytes) {
      var dt = Math.max(0.25, (now - prevSampleTime) / 1000)
      var dRate = (rx - prevRxBytes) / dt
      var uRate = (tx - prevTxBytes) / dt
      root.sessionDown += (rx - prevRxBytes)
      root.sessionUp += (tx - prevTxBytes)
      pushSample(dRate, uRate)
    } else {
      // First sample, or the active interface just changed -- no baseline
      // to diff against yet, so avoid manufacturing a spike.
      pushSample(0, 0)
    }

    prevRxBytes = rx
    prevTxBytes = tx
    prevSampleTime = now
    prevIface = currentIface
  }

  // Bumped once here, and only here -- the graph's scroll clock resets on
  // this alone, not on every history array that happens to change (LAN
  // included), so the primary WAN lines scroll on exactly the steady beat
  // they always did.
  property int syncTick: 0

  function pushSample(d, u) {
    downRate = d
    upRate = u
    if (d > peakDown) peakDown = d
    if (u > peakUp) peakUp = u
    var dh = downHistory.slice()
    dh.push(d)
    if (dh.length > historyMax) dh.shift()
    downHistory = dh
    var uh = upHistory.slice()
    uh.push(u)
    if (uh.length > historyMax) uh.shift()
    upHistory = uh
    var now2 = Date.now()
    var th = sampleTimes.slice()
    th.push(now2)
    if (th.length > historyMax) th.shift()
    sampleTimes = th
    var wanSlot = root.slotFor(now2, root.historyWindowSeconds, root.historyWindowSeconds)
    root.wanSlotShift = root.lastWanSlot < 0 ? 1 : Math.max(0, wanSlot - root.lastWanSlot)
    root.lastWanSlot = wanSlot
    root.syncTick++
  }

  // `timeout` bounds worst-case run time -- this fires as often as once a
  // second while the popup is open, so a wedged call needs to die well
  // before the next tick rather than piling up -- and `head -c` bounds how
  // much output is ever buffered, regardless of what the producer writes.
  Process {
    id: statusProc
    command: ["bash", "-c", "timeout --kill-after=1 3 omarchy-network-status --verbose | head -c 20000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sample(text)
    }
  }

  // Spawns two subprocesses per tick (omarchy-network-status + ss), so this
  // runs at full 1s resolution only while the popup is actually open and
  // that resolution is visible. Closed, the bar icon only needs to look
  // alive, not be perfectly live -- polling every 4s instead of every 1s
  // cuts that background process-spawn overhead by 4x for the (much more
  // common) time nobody's looking at it.
  readonly property int samplingIntervalMs: root.opened ? 1000 : 4000

  Timer {
    interval: root.samplingIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- LAN traffic (ss -tiepn, split by private/public remote IP) -----------
  //
  // omarchy-network-status gives one combined rx/tx total for the interface
  // -- there's no separate LAN counter at that level. This samples the same
  // TCP extended-info source the Usage tab uses, but every second instead of
  // every few, summing bytes_sent/bytes_received across only the
  // currently-open sockets whose remote address is private, then diffing
  // against the previous second's sum the same way the main WAN rate is
  // computed. Two real limitations, both disclosed in Settings: UDP isn't
  // counted (no byte counters), and a connection that closes between samples
  // takes its bytes with it -- this tracks *currently open* LAN sockets, not
  // a true cumulative LAN counter.

  // Theme-aware, not fixed: each static theme in Themes.js names its own
  // LAN pair (picked to sit apart from that theme's WAN pair on the color
  // wheel). The dynamic "omarchy" theme has no fixed LAN pair to draw from,
  // so it derives one live by rotating the current accent/urgent hues a
  // third of the way around the wheel (with a saturation/lightness floor so
  // a desaturated or very dark/light source color still produces a clearly
  // visible, distinct result) -- related to the live theme, but never the
  // same colors as WAN.
  function hueShift(base) {
    var hue = (base.hslHue + 1 / 3) % 1
    var sat = Math.max(0.55, base.hslSaturation)
    var light = Math.max(0.35, Math.min(0.7, base.hslLightness))
    return Qt.hsla(hue, sat, light, 1.0)
  }
  readonly property color lanDownColor: themeDynamic ? hueShift(Color.accent) : themeEntry.lanDownload
  readonly property color lanUpColor: themeDynamic ? hueShift(Color.urgent) : themeEntry.lanUpload

  property var lanDownHistory: []
  property var lanUpHistory: []
  // Parallel to lanDownHistory/lanUpHistory, same as sampleTimes above.
  property var lanSampleTimes: []
  readonly property var windowedLanDownHistoryFull: resampleByTime(lanSampleTimes, lanDownHistory, historyWindowSeconds, historyWindowSeconds, graphOverscanPoints)
  readonly property var windowedLanUpHistoryFull: resampleByTime(lanSampleTimes, lanUpHistory, historyWindowSeconds, historyWindowSeconds, graphOverscanPoints)
  readonly property var windowedLanDownHistory: windowedLanDownHistoryFull.slice(graphOverscanPoints)
  readonly property var windowedLanUpHistory: windowedLanUpHistoryFull.slice(graphOverscanPoints)
  readonly property var windowedLanDownOverscan: windowedLanDownHistoryFull.slice(0, graphOverscanPoints)
  readonly property var windowedLanUpOverscan: windowedLanUpHistoryFull.slice(0, graphOverscanPoints)

  property real prevLanReceived: -1
  property real prevLanSent: 0
  property real prevLanSampleTime: 0

  function sampleLan(text) {
    var conns = Model.parseConnectionsExtended(text)
    var received = 0
    var sent = 0
    for (var i = 0; i < conns.length; i++) {
      if (Model.isPrivateIp(conns[i].remoteIp)) {
        received += Number(conns[i].bytesReceived) || 0
        sent += Number(conns[i].bytesSent) || 0
      }
    }

    var now = Date.now()
    if (root.prevLanReceived >= 0 && received >= root.prevLanReceived && sent >= root.prevLanSent) {
      var dt = Math.max(0.25, (now - root.prevLanSampleTime) / 1000)
      pushLanSample((received - root.prevLanReceived) / dt, (sent - root.prevLanSent) / dt)
    } else {
      // First sample, or the live socket set lost bytes because some of
      // them closed -- no clean baseline, so don't manufacture a spike.
      pushLanSample(0, 0)
    }

    root.prevLanReceived = received
    root.prevLanSent = sent
    root.prevLanSampleTime = now
  }

  // LAN samples land via their own async process, on their own schedule --
  // this is what the graph's per-series syncTick keys off, so LAN scrolls
  // correctly on its own clock instead of riding WAN's (which is what
  // caused the LAN line specifically to judder: its geometry was updating
  // at moments that didn't line up with when the shared clock last reset).
  property int lanSyncTick: 0

  function pushLanSample(d, u) {
    var dh = lanDownHistory.slice()
    dh.push(d)
    if (dh.length > historyMax) dh.shift()
    lanDownHistory = dh
    var uh = lanUpHistory.slice()
    uh.push(u)
    if (uh.length > historyMax) uh.shift()
    lanUpHistory = uh
    var now2 = Date.now()
    var th = lanSampleTimes.slice()
    th.push(now2)
    if (th.length > historyMax) th.shift()
    lanSampleTimes = th
    var lanSlot = root.slotFor(now2, root.historyWindowSeconds, root.historyWindowSeconds)
    root.lanSlotShift = root.lastLanSlot < 0 ? 1 : Math.max(0, lanSlot - root.lastLanSlot)
    root.lastLanSlot = lanSlot
    root.lanSyncTick++
  }

  Process {
    id: lanStatsProc
    command: ["bash", "-c", "timeout --kill-after=1 3 ss -tiepn | head -c 400000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sampleLan(text)
    }
  }

  // ---- connections (ss -tup) ---------------------------------------------------

  property var connections: []
  property bool connectionsTruncated: false
  property var geoCache: ({})
  readonly property var groupedConnections: Model.groupConnectionsByProcess(connections)

  function refreshConnections() {
    connectionsProc.running = true
  }

  function handleConnections(text) {
    var parsed = Model.parseConnections(text)
    var maxRows = 60
    root.connectionsTruncated = parsed.length > maxRows
    root.connections = parsed.slice(0, maxRows)

    var toLookup = []
    for (var i = 0; i < root.connections.length; i++) {
      var ip = root.connections[i].remoteIp
      if (!Model.isPrivateIp(ip) && !root.geoCache[ip] && toLookup.indexOf(ip) === -1)
        toLookup.push(ip)
    }
    root.queueGeoLookups(toLookup)

    root.checkNewApps(root.connections)
  }

  function flagFor(ip) {
    if (Model.isPrivateIp(ip)) return "🏠"
    var g = root.geoCache[ip]
    if (!g || !g.countryCode) return "🌐"
    var flag = Model.countryFlagEmoji(g.countryCode)
    return (flag ? flag + " " : "") + g.countryCode
  }

  // `timeout` bounds worst-case run time (a wedged `ss` shouldn't be able to
  // hang this popup or pile up indefinitely across ticks) and `head -c`
  // bounds how much output we'll ever buffer into memory/StdioCollector,
  // regardless of how much the producer actually writes.
  Process {
    id: connectionsProc
    command: ["bash", "-c", "timeout --kill-after=1 4 ss -tup | head -c 400000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleConnections(text)
    }
  }

  // Runs whether or not the popup is open -- this is what feeds the new-app
  // alert below, which is meant to work in the background like the source
  // material's "discreet alert that won't interrupt your workflow."
  Timer {
    interval: 6000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshConnections()
  }

  // ---- new-app alert -----------------------------------------------------------
  //
  // The first connections poll just primes the "seen" set (everything
  // already running looks "new" otherwise, which would fire a burst of
  // alerts the moment the shell starts). After that, any process name that
  // shows up for the first time gets one discreet notification.

  property var seenProcesses: ({})
  property bool connectionsPrimed: false
  property int newAppAlertCount: 0

  function checkNewApps(list) {
    // Object.create(null): `name` is a process name straight out of `ss`
    // output -- a locally-running process can name itself anything,
    // including "__proto__", which a plain {} would let collide with
    // Object.prototype.
    var stillSeen = Object.create(null)
    for (var k in root.seenProcesses) stillSeen[k] = true
    var freshNames = []
    for (var i = 0; i < list.length; i++) {
      var name = list[i].process
      if (!name) continue
      if (!stillSeen[name]) {
        stillSeen[name] = true
        freshNames.push(name)
      }
    }
    root.seenProcesses = stillSeen

    if (!root.connectionsPrimed) {
      root.connectionsPrimed = true
      return
    }
    if (freshNames.length === 0) return

    // The Usage tab's "new apps" count keeps tracking either way -- it's a
    // passive number, not an interruption -- but the OS desktop
    // notification itself is opt-in (see newAppNotifications in Settings).
    root.newAppAlertCount += freshNames.length
    if (!root.newAppNotifications) return

    notifyProc.body = freshNames.length === 1
      ? (freshNames[0] + " just started talking to the internet")
      : (freshNames.join(", ") + " just started talking to the internet")
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    property string body: ""
    command: ["omarchy-notification-send", "--app-name", "OmaGlass", "-u", "low",
      "New app on your network", body]
  }

  // One IP looked up per request against ipwho.is over real HTTPS, queued
  // and processed one at a time (same shape as the reverse-DNS queue
  // below) -- not batched. ip-api.com (used previously) turned out to
  // reject HTTPS entirely on its free tier ("SSL unavailable for this
  // endpoint", confirmed directly against its API), which meant every
  // lookup went out in cleartext and, being a single POST of the *entire*
  // pending batch, put the complete list of a user's current remote IPs in
  // one place: the request body, which curl also exposed via argv (visible
  // to any other local process reading /proc/<pid>/cmdline while it ran).
  // One HTTPS GET per address fixes the transport (encrypted, can't be
  // silently tampered with in transit) and means at most a single address
  // is ever in flight at once, the same as any other simple GET-based CLI
  // lookup -- not a standing list of everywhere the user is connected.
  property var pendingGeoQueue: []
  property string geoLookupTarget: ""

  function queueGeoLookups(ips) {
    var q = root.pendingGeoQueue.slice()
    for (var i = 0; i < ips.length; i++) {
      // Capped so a burst of many distinct new remote IPs at once can't
      // grow this queue without bound.
      if (q.indexOf(ips[i]) === -1 && q.length < 200) q.push(ips[i])
    }
    root.pendingGeoQueue = q
    root.processNextGeoLookup()
  }

  // Set on a failed/rate-limited lookup, cleared on success. While in
  // effect, processNextGeoLookup below defers rather than firing more
  // requests -- ipwho.is's free tier rate-limits per caller, and without
  // this, the connections poll (every 6s, popup open or not) would just
  // keep re-queuing every still-unresolved IP forever and hammering it the
  // whole time. `handleConnections`'s own re-queue on the next poll is what
  // resumes checking once this expires, no separate timer needed.
  property real geoBackoffUntil: 0
  property int geoBackoffMs: 0
  readonly property int geoBackoffBaseMs: 30000
  // Capped well under a real Retry-After (ipwho.is has been observed to
  // send one in the tens of thousands of seconds for an exhausted daily
  // quota) -- waiting out the exact value would mean not even retrying for
  // the better part of a day on a single header read. Retrying at this
  // cadence instead is still a small fraction of the request volume that
  // caused the limit in the first place, while recovering promptly once it
  // actually clears.
  readonly property int geoBackoffMaxMs: 1800000

  // Proactive pacing, independent of the reactive backoff above: without
  // this, a burst of many distinct new remote IPs at once (e.g. opening
  // Connections for the first time with a couple dozen active
  // connections) would fire that many lookups back-to-back, limited only
  // by network round-trip time -- easily several requests per second,
  // which risks tripping a per-second rate limit on its own before ever
  // accumulating toward a longer-window quota. One request per second is
  // still fast enough that a real connections list finishes resolving
  // within a few seconds, while staying a conservative, unhurried rate
  // against a free public service.
  readonly property int geoMinIntervalMs: 1000
  property real geoLastRequestAt: 0

  function processNextGeoLookup() {
    if (root.geoLookupTarget !== "" || root.pendingGeoQueue.length === 0) return
    if (Date.now() < root.geoBackoffUntil) return
    var sinceLast = Date.now() - root.geoLastRequestAt
    if (sinceLast < root.geoMinIntervalMs) {
      geoPaceTimer.interval = Math.max(1, root.geoMinIntervalMs - sinceLast)
      geoPaceTimer.restart()
      return
    }
    var q = root.pendingGeoQueue.slice()
    root.geoLookupTarget = q.shift()
    root.pendingGeoQueue = q
    root.geoLastRequestAt = Date.now()
    geoProc.running = true
  }

  Timer {
    id: geoPaceTimer
    repeat: false
    onTriggered: root.processNextGeoLookup()
  }

  Process {
    id: geoProc
    // -q must be curl's very first option (that's how curl itself decides
    // whether to honor it at all) -- it disables reading ~/.curlrc, so an
    // ambient config on the machine this plugin runs on can't silently add
    // or change anything about this request despite every flag below being
    // spelled out explicitly. --proto/--tlsv1.2: refuse anything but a
    // real, modern-TLS HTTPS connection outright (no silent downgrade).
    // --max-redirs 0: never follow a redirect to an unexpected host.
    // `timeout` bounds total run time; `head -c` bounds how much of the
    // response we'll ever read. No --fail here (unlike other lookups in
    // this file) -- a rate-limit response's body and headers are exactly
    // what tells the backoff logic below how long to actually wait, so
    // this needs to see them rather than have curl discard them.
    command: ["bash", "-c",
      "timeout --kill-after=2 6 curl -q -sS --max-time 5 --connect-timeout 3 --proto '=https' --tlsv1.2 --max-redirs 0 \"https://ipwho.is/$1\" -w '\\n@@GEOMETA@@%{http_code}@@%{header_json}' | head -c 8200",
      "_", root.geoLookupTarget]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.parseGeoSingle(text)
        if (result.country) {
          var merged = {}
          for (var k in root.geoCache) merged[k] = root.geoCache[k]
          merged[root.geoLookupTarget] = result.country
          root.geoCache = root.capCache(merged, 500)
          root.geoBackoffMs = 0
          root.geoBackoffUntil = 0
        } else {
          var backoffMs = result.retryAfterSeconds > 0
            ? Math.min(result.retryAfterSeconds * 1000, root.geoBackoffMaxMs)
            : (root.geoBackoffMs > 0 ? Math.min(root.geoBackoffMs * 2, root.geoBackoffMaxMs) : root.geoBackoffBaseMs)
          root.geoBackoffMs = backoffMs
          root.geoBackoffUntil = Date.now() + backoffMs
        }
        root.geoLookupTarget = ""
        root.processNextGeoLookup()
      }
    }
  }

  // Both lookup caches (this and hostCache below) only ever grow -- over a
  // long-running session with many distinct remote IPs, that's an unbounded
  // JS object. Capped at a generous size and evicted oldest-first (object
  // key order is insertion order here, since IPs aren't array-index-like
  // keys) once over the cap, so long uptime doesn't creep memory up forever.
  function capCache(obj, maxSize) {
    var keys = Object.keys(obj)
    if (keys.length <= maxSize) return obj
    var drop = keys.length - maxSize
    var out = {}
    for (var i = drop; i < keys.length; i++) out[keys[i]] = obj[keys[i]]
    return out
  }

  // ---- whois, on demand ----------------------------------------------------
  //
  // Keyed by a stable per-row string, not by IP or a flat list index:
  // several connections can share a remote IP (the same host, multiple
  // sockets), so keying purely on the IP made every row with that IP expand
  // together when only one was clicked. And now that Connections nests rows
  // under a process header, there's no single flat index to key by either --
  // a row key built from the connection's own fields (process+ip+port+proto)
  // is stable across the nested structure and unique per row in practice.
  // Only one row's key can ever be the open one at a time.

  property string whoisRowKey: ""
  property string whoisIp: ""
  property string whoisText: ""
  property bool whoisLoading: false

  // localPort is part of the key -- without it, two distinct sockets that
  // happen to share process+remoteIp+remotePort+protocol (e.g. several
  // parallel connections to the same server:443) collide onto one key, so
  // clicking either row expanded both of them together instead of just the
  // one clicked.
  function connectionRowKey(conn) {
    return conn.process + "|" + conn.localPort + "|" + conn.remoteIp + "|" + conn.remotePort + "|" + conn.protocol
  }

  // Single-flight: at most one whoisProc invocation is ever actually
  // running at a time. Clicking a second row while the first is still in
  // flight used to just overwrite whoisProc.targetIp and start a second
  // run "on top of" the first (or race with whatever Process.running=true
  // on an already-running Process actually does) -- since the completion
  // guard compared two properties (whoisProc.targetIp and root.whoisIp)
  // that a second click ALSO overwrites, both could end up agreeing with
  // each other again by the time the FIRST (stale) response arrived,
  // making it look like a match for the second request and displaying the
  // wrong IP's data. Killing the in-flight process and queuing the new
  // request until it actually exits (see onRunningChanged below) means
  // there is only ever one real request in flight, so that comparison is
  // never fooled by a second click's overwrite landing in between.
  property bool whoisPendingRestart: false
  property string whoisPendingIp: ""
  property string whoisPendingRowKey: ""

  function toggleWhois(rowKey, ip) {
    if (root.whoisRowKey === rowKey) {
      root.collapseWhois()
      return
    }
    root.whoisRowKey = rowKey
    root.whoisIp = ip
    root.whoisText = ""
    root.whoisLoading = true
    if (whoisProc.running) {
      root.whoisPendingRestart = true
      root.whoisPendingIp = ip
      root.whoisPendingRowKey = rowKey
      whoisProc.signal(15) // SIGTERM; onRunningChanged starts the queued request once it actually exits
      return
    }
    whoisProc.targetIp = ip
    whoisProc.running = true
  }

  function collapseWhois() {
    root.whoisRowKey = ""
    root.whoisIp = ""
    root.whoisText = ""
    root.whoisLoading = false
  }

  Process {
    id: whoisProc
    property string targetIp: ""
    // No external `whois` binary required -- this speaks the WHOIS
    // protocol (RFC 3912: connect on TCP/43, send "query\r\n", read until
    // the peer closes) directly over bash's /dev/tcp, so the plugin has no
    // dependency beyond what a stock Omarchy install already has. Queries
    // IANA's root server first and follows its one `refer:` pointer to the
    // actual regional registry for the real record -- the same
    // single-hop referral chase the standalone `whois` CLI does for IP
    // lookups.
    //
    // The referral target is checked against a fixed allowlist of the
    // five real regional internet registries before it's ever connected
    // to: `refer:` is taken verbatim from IANA's plaintext, unauthenticated
    // response, so a network attacker able to tamper with or spoof that
    // response could otherwise redirect this connection to an arbitrary
    // host of their choosing (including an internal/link-local address).
    // If the value isn't one of these five, the plugin simply keeps IANA's
    // own response instead of connecting anywhere else.
    //
    // The whole two-hop lookup runs under one absolute `timeout` (rather
    // than one per hop, which could add up to double the wait) and each
    // socket read is capped with `head -c` so a slow, hostile, or
    // just-broken server can't hang the popup or hand back unbounded data.
    // The `Process` type has no built-in run-time-limit property, so the
    // single absolute deadline for both hops together is enforced by
    // wrapping the whole bash invocation in the `timeout` command itself.
    command: ["timeout", "--kill-after=2", "12", "bash", "-c", `
      TARGET_IP="$1"
      RIR_ALLOWLIST=" whois.arin.net whois.ripe.net whois.apnic.net whois.lacnic.net whois.afrinic.net "
      q() {
        exec 3<>"/dev/tcp/$1/43" || return 1
        printf "%s\\r\\n" "$TARGET_IP" >&3
        head -c 65536 <&3
      }
      resp1=$(q whois.iana.org) || { echo "Could not reach the whois service."; exit 0; }
      refer=$(printf '%s\\n' "$resp1" | grep -i '^refer:' | head -1 | sed 's/^[Rr]efer:[[:space:]]*//' | tr -d '\\r\\n ' | tr 'A-Z' 'a-z')
      case "$RIR_ALLOWLIST" in
        *" $refer "*)
          resp2=$(q "$refer")
          if [ -n "$resp2" ]; then printf '%s\\n' "$resp2"; else printf '%s\\n' "$resp1"; fi
          ;;
        *)
          printf '%s\\n' "$resp1"
          ;;
      esac
    `, "_", targetIp]
    // Fires once the process has actually stopped -- including from the
    // SIGTERM toggleWhois sends when superseding it -- so a queued request
    // (see whoisPendingRestart above) only ever starts after the previous
    // one is truly gone, never overlapping it.
    onRunningChanged: {
      if (whoisProc.running || !root.whoisPendingRestart) return
      root.whoisPendingRestart = false
      // The row that queued this may itself have been collapsed or
      // superseded again while the kill was still taking effect -- only
      // start it if it's still the one the UI is actually showing as
      // loading.
      if (root.whoisRowKey !== root.whoisPendingRowKey) return
      whoisProc.targetIp = root.whoisPendingIp
      whoisProc.running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A second click (closing, or a different IP) may have landed
        // before this one finished -- don't overwrite with a stale result.
        // Safe against the stale-match race a mutable-property comparison
        // like this could otherwise have (see toggleWhois's header
        // comment) because toggleWhois no longer lets a second request
        // start until this one has actually stopped -- so whoisProc's own
        // targetIp can't have been overwritten out from under an
        // in-flight run the way it previously could.
        if (whoisProc.targetIp !== root.whoisIp || root.whoisRowKey === "") return
        root.whoisText = Model.formatWhois(text)
        root.whoisLoading = false
      }
    }
  }

  // ---- LAN devices (ip neigh show) ----------------------------------------------

  property var devices: []

  function refreshDevices() {
    devicesProc.running = true
  }

  Process {
    id: devicesProc
    command: ["bash", "-c", "timeout --kill-after=1 4 ip neigh show | head -c 100000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.devices = Model.parseNeighbors(text)
    }
  }

  Timer {
    interval: 10000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDevices()
  }

  // ---- usage: apps / hosts / traffic type / countries -----------------------
  //
  // A second, TCP-only poll with `-i` (extended socket info), which is what
  // exposes the kernel's real bytes_sent/bytes_received counters for each
  // connection -- the one legitimate source of byte-volume data available
  // without root. Grouped four ways to match the source material's Usage
  // view; UDP (DNS, mDNS, SSDP, ...) shows up in Connections but not here,
  // since those sockets carry no byte counters to sum.

  property var usageConnections: []
  property var hostCache: ({})
  property var pendingHostQueue: []
  property string hostLookupTarget: ""

  function refreshUsage() {
    usageProc.running = true
  }

  function handleUsage(text) {
    root.usageConnections = Model.parseConnectionsExtended(text)

    var geoLookup = []
    var hostLookup = []
    for (var i = 0; i < root.usageConnections.length; i++) {
      var ip = root.usageConnections[i].remoteIp
      if (!Model.isPrivateIp(ip)) {
        if (!root.geoCache[ip] && geoLookup.indexOf(ip) === -1) geoLookup.push(ip)
        if (root.hostCache[ip] === undefined && hostLookup.indexOf(ip) === -1) hostLookup.push(ip)
      }
    }
    root.queueGeoLookups(geoLookup)
    root.queueHostLookups(hostLookup)
  }

  function queueHostLookups(ips) {
    var q = root.pendingHostQueue.slice()
    for (var i = 0; i < ips.length; i++) {
      // Capped so a burst of many distinct new remote IPs at once can't
      // grow this queue without bound.
      if (q.indexOf(ips[i]) === -1 && q.length < 200) q.push(ips[i])
    }
    root.pendingHostQueue = q
    root.processNextHostLookup()
  }

  function processNextHostLookup() {
    if (root.hostLookupTarget !== "" || root.pendingHostQueue.length === 0) return
    var q = root.pendingHostQueue.slice()
    root.hostLookupTarget = q.shift()
    root.pendingHostQueue = q
    hostProc.running = true
  }

  function hostLabel(ip) {
    var h = root.hostCache[ip]
    return h ? h : ip
  }

  readonly property var usageByApp: Model.aggregateBytes(usageConnections, function(c) { return c.process || "Unknown" })
  readonly property var usageByHost: Model.aggregateBytes(usageConnections, function(c) { return root.hostLabel(c.remoteIp) })
  readonly property var usageByType: Model.aggregateBytes(usageConnections, function(c) { return Model.serviceName(c.remotePort) })
  // Keyed as "code|name" so the Usage view can split off the code to render
  // a flag next to the country name.
  readonly property var usageByCountry: Model.aggregateBytes(usageConnections, function(c) {
    if (Model.isPrivateIp(c.remoteIp)) return "--|Local Network"
    var g = root.geoCache[c.remoteIp]
    var code = (g && g.countryCode) ? g.countryCode : "--"
    var name = (g && g.country) ? g.country : "Unknown"
    return code + "|" + name
  })

  readonly property real usageWanBytes: {
    var s = 0
    for (var i = 0; i < usageConnections.length; i++) {
      var c = usageConnections[i]
      if (!Model.isPrivateIp(c.remoteIp)) s += (Number(c.bytesSent) || 0) + (Number(c.bytesReceived) || 0)
    }
    return s
  }
  readonly property real usageLanBytes: {
    var s = 0
    for (var j = 0; j < usageConnections.length; j++) {
      var c2 = usageConnections[j]
      if (Model.isPrivateIp(c2.remoteIp)) s += (Number(c2.bytesSent) || 0) + (Number(c2.bytesReceived) || 0)
    }
    return s
  }
  readonly property string usageWanText: Model.formatBytes(usageWanBytes)
  readonly property string usageLanText: Model.formatBytes(usageLanBytes)

  Process {
    id: usageProc
    command: ["bash", "-c", "timeout --kill-after=1 4 ss -tiepn | head -c 400000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleUsage(text)
    }
  }

  Timer {
    interval: 6000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshUsage()
  }

  Process {
    id: hostProc
    command: ["bash", "-c", "timeout --kill-after=1 3 getent hosts \"$1\" | head -c 4000", "_", root.hostLookupTarget]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var resolved = Model.parseGetentHost(text)
        var merged = {}
        for (var k in root.hostCache) merged[k] = root.hostCache[k]
        merged[root.hostLookupTarget] = resolved || root.hostLookupTarget
        root.hostCache = root.capCache(merged, 500)
        root.hostLookupTarget = ""
        root.processNextHostLookup()
      }
    }
  }

  // ---- theme ---------------------------------------------------------------

  property string themeId: "omarchy"
  readonly property var themeEntry: Themes.byId(themeId)
  readonly property bool themeDynamic: !!themeEntry.dynamic
  readonly property color downColor: themeDynamic ? Color.accent : themeEntry.download
  readonly property color upColor: themeDynamic ? Color.urgent : themeEntry.upload

  // Secondary/label text blended from the popup's own foreground rather than
  // the shell's flat `Color.muted` token -- some themes leave that token dim
  // enough to be hard to read, and a blend against the real foreground stays
  // legible across every theme while still reading as "muted".
  readonly property color mutedText: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.68)

  // Plain white or black, picked by the popup background's own luminance --
  // for chrome-free icons (like the settings glyph) that want a crisp,
  // always-legible mark rather than a theme-tinted one.
  readonly property color contrastText: {
    var bg = Color.popups.background
    var luminance = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
    return luminance > 0.5 ? "#000000" : "#ffffff"
  }

  // When true (the default), the bar icon's tiny graph ignores the WAN
  // theme colors above and instead uses the same neutral color every other
  // bar icon glyph uses, so it reads as "an icon" rather than a colored
  // widget. The popup graph always keeps the theme colors -- this only
  // affects the bar icon.
  property bool barMonotone: true
  readonly property color barGraphDownColor: root.barMonotone ? root.barForeground : root.downColor
  readonly property color barGraphUpColor: root.barMonotone ? root.barForeground : root.upColor

  // Off by default -- opt-in, not opt-out. Only gates the OS desktop
  // notification itself; the "new apps" count shown in the Usage tab keeps
  // tracking regardless, since that's a passive in-app number rather than
  // an interruption.
  property bool newAppNotifications: false

  // What historyWindowSeconds (the Traffic graph's window) starts out as on
  // a fresh popup -- 120s (2m) until changed here. Picking a window in the
  // Traffic tab itself only affects that session's live view, not this.
  property int defaultHistoryWindowSeconds: 120

  function setTheme(id) {
    if (!Themes.exists(id)) return
    themeId = id
    writeState()
  }

  function setBarMonotone(enabled) {
    barMonotone = enabled
    writeState()
  }

  function setNewAppNotifications(enabled) {
    newAppNotifications = enabled
    writeState()
  }

  function setDefaultHistoryWindow(seconds) {
    defaultHistoryWindowSeconds = seconds
    writeState()
  }

  function writeState() {
    themeWriteProc.themeIdArg = root.themeId
    themeWriteProc.monotoneArg = root.barMonotone ? "true" : "false"
    themeWriteProc.notifyArg = root.newAppNotifications ? "true" : "false"
    themeWriteProc.windowArg = String(root.defaultHistoryWindowSeconds)
    themeWriteProc.running = true
  }

  // Copies plain text to the system clipboard via wl-copy -- same recipe
  // omarchy.network uses for its copyable detail rows.
  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(String(value)) + " | wl-copy"])
  }

  // State file lives at $HOME/.local/state/omarchy/omaglass/theme.json.
  // themeReadProc/themeWriteProc below walk to it a component at a time
  // rather than resolving that path in one shot -- see their comments.
  readonly property var validHistoryWindows: [30, 120, 600, 1800]

  function applyThemeFile(raw) {
    try {
      var parsed = JSON.parse(raw)
      if (parsed && typeof parsed.theme === "string" && Themes.exists(parsed.theme))
        root.themeId = parsed.theme
      if (parsed && typeof parsed.barMonotone === "boolean")
        root.barMonotone = parsed.barMonotone
      if (parsed && typeof parsed.newAppNotifications === "boolean")
        root.newAppNotifications = parsed.newAppNotifications
      if (parsed && root.validHistoryWindows.indexOf(parsed.defaultHistoryWindowSeconds) !== -1)
        root.defaultHistoryWindowSeconds = parsed.defaultHistoryWindowSeconds
    } catch (e) {
      // No saved settings yet -- keep the defaults.
    }
  }

  // Reads the persisted state file once at startup. Not FileView (a
  // high-level component with no symlink/byte/blocking controls), and not
  // a plain `head -c` on the full path either -- that re-walks every
  // ancestor on the spot, following whatever symlink an attacker swapped
  // in along the way. Instead this opens HOME and then each path
  // component -- .local, state, omarchy, omaglass -- one at a time, each
  // one relative to its parent's already-open descriptor via
  // /proc/self/fd (openat() semantics). Once the walk is past a
  // component, a symlink swapped in there can no longer redirect
  // anything: nothing below ever names it by path again. The leaf file is
  // opened the same way off the held directory fd and is rejected unless
  // it is a regular file this user owns; `head -c` caps bytes and the
  // outer `timeout` caps time, so a FIFO/device (already excluded by the
  // `-f` test) still could not hang the shell. FileView's live-reload
  // isn't needed: manifest.json disallows multiple instances, so nothing
  // else writes this file while we run, and every setter updates the
  // in-memory value directly -- the file is read once, to restore a
  // previous session. Addresses the state-boundary blocker in the
  // marketplace security review (omarchy-plugin-marketplace#4300).
  Process {
    id: themeReadProc
    running: true
    command: ["timeout", "--kill-after=1", "3", "bash", "-c", `
      H="$1"
      [ -n "$H" ] && [ -d "$H" ] && [ ! -L "$H" ] || exit 0
      exec {dfd}<"$H" || exit 0
      for seg in .local state omarchy omaglass; do
        p="/proc/self/fd/$dfd/$seg"
        [ -L "$p" ] && exit 0
        [ -d "$p" ] || exit 0
        prev=$dfd
        exec {dfd}<"$p" || exit 0
        eval "exec $prev<&-"
      done
      D="/proc/self/fd/$dfd"
      [ -d "$D/." ] || exit 0
      F="$D/theme.json"
      [ -L "$F" ] && exit 0
      [ -e "$F" ] && [ ! -f "$F" ] && exit 0
      [ -f "$F" ] && [ -O "$F" ] || exit 0
      exec {ffd}<"$F" || exit 0
      head -c 4096 -- "/proc/self/fd/$ffd"
    `, "_", Quickshell.env("HOME")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyThemeFile(text)
    }
  }

  // Publishes the state file by atomic rename() of a freshly mktemp'd
  // file in the same directory -- never a `>` redirect through a
  // predictable name, which would write straight through a pre-planted
  // symlink or FIFO. The directory is reached by the same
  // component-at-a-time openat() walk as the reader: HOME is opened, then
  // .local, state, omarchy, omaglass, each relative to its parent's held
  // descriptor via /proc/self/fd, creating any missing component 0700.
  // Everything that follows -- mktemp, chmod, mv -- names its target only
  // as /proc/self/fd/<dirfd>/..., so once the walk is done no ancestor is
  // ever re-resolved by path and a symlink swapped in afterward cannot
  // redirect the temp file or the final publish. `umask 077` plus an
  // explicit owner check keep both private; the outer `timeout` bounds
  // the whole thing. Addresses the state-boundary blocker in the
  // marketplace security review (omarchy-plugin-marketplace#4300). The
  // one remaining sliver is the initial open() of HOME itself -- a single
  // atomic syscall with no check-then-use inside it, anchored on the
  // HOME value the shell was started with.
  Process {
    id: themeWriteProc
    property string themeIdArg: ""
    property string monotoneArg: "true"
    property string notifyArg: "false"
    property string windowArg: "120"
    command: ["timeout", "--kill-after=1", "5", "bash", "-c", `
      umask 077
      H="$1"
      [ -n "$H" ] && [ -d "$H" ] && [ ! -L "$H" ] || exit 1
      exec {dfd}<"$H" || exit 1
      for seg in .local state omarchy omaglass; do
        p="/proc/self/fd/$dfd/$seg"
        [ -L "$p" ] && exit 1
        [ -d "$p" ] || mkdir -m 0700 "$p" 2>/dev/null || true
        { [ -d "$p" ] && [ ! -L "$p" ]; } || exit 1
        prev=$dfd
        exec {dfd}<"$p" || exit 1
        eval "exec $prev<&-"
      done
      D="/proc/self/fd/$dfd"
      { [ -d "$D/." ] && [ -O "$D/." ]; } || exit 1
      tmp=$(mktemp "$D/.theme.json.XXXXXX") || exit 1
      [ -L "$tmp" ] && { rm -f "$tmp"; exit 1; }
      printf '{"theme":"%s","barMonotone":%s,"newAppNotifications":%s,"defaultHistoryWindowSeconds":%s}' "$2" "$3" "$4" "$5" > "$tmp"
      chmod 0600 "$tmp"
      mv -f "$tmp" "$D/theme.json"
    `, "_", Quickshell.env("HOME"), themeIdArg, monotoneArg, notifyArg, windowArg]
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // ---- popup content ---------------------------------------------------------

  // Pixels of scroll per unit of WheelEvent.angleDelta.y (typically ±120 for
  // one physical notch, smaller/continuous for a trackpad). Roughly 6x a
  // plain Flickable's own default notch step -- see the WheelHandler below.
  readonly property real wheelScrollScale: 1.5

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(Math.min(mainColumn.implicitHeight, Style.space(620)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: contentFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        // Flickable's own built-in wheel handling moves content a small
        // fixed amount per notch -- fine for a short list, but this popup's
        // content (especially Settings and Connections, both several
        // screens tall) took many notches to reach the bottom. WheelHandler
        // intercepts the event ahead of Flickable's own handling (Qt Quick
        // gives an Item's pointer handlers first refusal), so `target: null`
        // plus a manual contentY adjustment fully replaces it rather than
        // stacking on top of it.
        WheelHandler {
          target: null
          onWheel: function(event) {
            var maxY = Math.max(0, contentFlick.contentHeight - contentFlick.height)
            var next = contentFlick.contentY - event.angleDelta.y * root.wheelScrollScale
            contentFlick.contentY = Math.max(0, Math.min(maxY, next))
          }
        }

        Column {
          id: mainColumn
          width: contentFlick.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            height: Math.max(titleCol.implicitHeight, gearBtn.height)

            Column {
              id: titleCol
              anchors.left: parent.left
              anchors.right: gearBtn.left
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "OmaGlass"
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: root.connectionLabel
                color: root.mutedText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // Bare glyph, no button chrome -- same minimal treatment as the
            // Traffic tab's pause control. Still named gearBtn/sized 28x28
            // so titleCol's anchors.right and this Item's own height binding
            // above don't need to change.
            //
            // The gear is hand-drawn on a Canvas rather than the "⚙" text
            // character: that codepoint turned out to render as a fixed
            // light-blue icon-font glyph on this system, ignoring the
            // `color` property entirely no matter what it was set to.
            // Drawing it ourselves is the only way to actually control its
            // color.
            Item {
              id: gearBtn
              anchors.right: parent.right
              anchors.top: parent.top
              width: Style.space(28)
              height: Style.space(28)
              opacity: gearMouse.containsMouse ? 1.0 : 0.85

              Canvas {
                id: gearIcon
                visible: root.activeTab !== "settings"
                anchors.centerIn: parent
                width: Style.space(16)
                height: Style.space(16)
                property color iconColor: root.contrastText
                onIconColorChanged: requestPaint()
                Component.onCompleted: requestPaint()

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  var cx = width / 2
                  var cy = height / 2
                  var outerR = width / 2
                  var innerR = outerR * 0.55
                  var toothR = outerR * 0.85
                  var valleyR = innerR + (toothR - innerR) * 0.35
                  var teeth = 6

                  ctx.beginPath()
                  for (var i = 0; i < teeth * 2; i++) {
                    var angle = (Math.PI * 2 * i) / (teeth * 2)
                    var r = (i % 2 === 0) ? toothR : valleyR
                    var x = cx + r * Math.cos(angle)
                    var y = cy + r * Math.sin(angle)
                    if (i === 0) ctx.moveTo(x, y)
                    else ctx.lineTo(x, y)
                  }
                  ctx.closePath()
                  ctx.fillStyle = iconColor
                  ctx.fill()

                  ctx.beginPath()
                  ctx.arc(cx, cy, innerR * 0.5, 0, Math.PI * 2)
                  ctx.fillStyle = Color.popups.background
                  ctx.fill()
                }
              }

              Text {
                visible: root.activeTab === "settings"
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "←"
                color: root.contrastText
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: gearMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openSettings()
              }
            }
          }

          Row {
            visible: root.activeTab !== "settings"
            spacing: Style.space(8)

            Repeater {
              model: [
                { key: "traffic", label: "Traffic" },
                { key: "connections", label: "Connections" },
                { key: "usage", label: "Usage" },
                { key: "devices", label: "Devices" }
              ]

              Rectangle {
                required property var modelData
                readonly property bool active: root.activeTab === modelData.key
                width: Style.space(84)
                height: Style.space(28)
                radius: Style.space(14)
                color: active
                  ? Util.alpha(Color.accent, 0.20)
                  : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
                border.width: active ? 1 : 0
                border.color: Color.accent

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: active ? Color.popups.text : root.mutedText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: active
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activeTab = modelData.key
                }
              }
            }
          }

          Loader {
            width: parent.width
            sourceComponent: root.activeTab === "traffic" ? trafficComp
              : root.activeTab === "connections" ? connectionsComp
              : root.activeTab === "usage" ? usageComp
              : root.activeTab === "devices" ? devicesComp
              : settingsComp
          }
        }
      }
    }
  }

  Component { id: trafficComp; TrafficView { panel: root } }
  Component { id: connectionsComp; ConnectionsView { panel: root } }
  Component { id: usageComp; UsageView { panel: root } }
  Component { id: devicesComp; DevicesView { panel: root } }
  Component { id: settingsComp; SettingsView { panel: root } }
}

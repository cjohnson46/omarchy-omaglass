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
  property real downRate: 0
  property real upRate: 0
  property real peakDown: 0
  property real peakUp: 0
  property real sessionDown: 0
  property real sessionUp: 0
  property string iface: ""
  property string ifaceType: ""
  property string ssid: ""

  property int historyWindowSeconds: 120

  // Padded with leading zeros to always be exactly historyWindowSeconds long,
  // even in the first minutes of a session before that much real history
  // exists. Without this, the graph's point count grew by one every second
  // until the window filled -- and since each point is spaced width/(n-1)
  // apart, a growing n means the pixel spacing shrinks every single rebuild,
  // so the whole curve visibly compresses leftward instead of scrolling.
  // That's what made the graph look like it "didn't scroll properly" until
  // a full window's worth of history had accumulated: below that, every
  // point was being repositioned every second, not just the newest one.
  function padToWindow(values, targetLength) {
    var n = targetLength !== undefined ? targetLength : historyWindowSeconds
    var raw = values.slice(Math.max(0, values.length - n))
    if (raw.length >= n) return raw
    var padded = new Array(n - raw.length)
    for (var i = 0; i < padded.length; i++) padded[i] = 0
    return padded.concat(raw)
  }
  readonly property var windowedDownHistory: padToWindow(downHistory)
  readonly property var windowedUpHistory: padToWindow(upHistory)

  // Same fixed-length padding, for the small bar-icon graph (40 samples)
  // independent of the popup's selected window.
  readonly property int barHistoryPoints: 40
  readonly property var barDownHistory: padToWindow(downHistory, barHistoryPoints)
  readonly property var barUpHistory: padToWindow(upHistory, barHistoryPoints)

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
  readonly property var windowedLanDownHistory: padToWindow(lanDownHistory)
  readonly property var windowedLanUpHistory: padToWindow(lanUpHistory)

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

    root.newAppAlertCount += freshNames.length
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

  function processNextGeoLookup() {
    if (root.geoLookupTarget !== "" || root.pendingGeoQueue.length === 0) return
    var q = root.pendingGeoQueue.slice()
    root.geoLookupTarget = q.shift()
    root.pendingGeoQueue = q
    geoProc.running = true
  }

  Process {
    id: geoProc
    // --proto/--tlsv1.2: refuse anything but a real, modern-TLS HTTPS
    // connection outright (no silent downgrade). --max-redirs 0: never
    // follow a redirect to an unexpected host. --fail: don't treat an
    // HTTP error page as a real response. `timeout` bounds total run time;
    // `head -c` bounds how much of the response we'll ever read.
    command: ["bash", "-c",
      "timeout --kill-after=2 6 curl -sS --max-time 5 --connect-timeout 3 --proto '=https' --tlsv1.2 --max-redirs 0 --fail \"https://ipwho.is/$1\" | head -c 8000",
      "_", root.geoLookupTarget]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseGeoSingle(text)
        if (parsed) {
          var merged = {}
          for (var k in root.geoCache) merged[k] = root.geoCache[k]
          merged[root.geoLookupTarget] = parsed
          root.geoCache = root.capCache(merged, 500)
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

  function toggleWhois(rowKey, ip) {
    if (root.whoisRowKey === rowKey) {
      root.collapseWhois()
      return
    }
    root.whoisRowKey = rowKey
    root.whoisIp = ip
    root.whoisText = ""
    root.whoisLoading = true
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A second click (closing, or a different IP) may have landed
        // before this one finished -- don't overwrite with a stale result.
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

  function setTheme(id) {
    if (!Themes.exists(id)) return
    themeId = id
    writeState()
  }

  function setBarMonotone(enabled) {
    barMonotone = enabled
    writeState()
  }

  function writeState() {
    themeWriteProc.themeIdArg = root.themeId
    themeWriteProc.monotoneArg = root.barMonotone ? "true" : "false"
    themeWriteProc.running = true
  }

  // Copies plain text to the system clipboard via wl-copy -- same recipe
  // omarchy.network uses for its copyable detail rows.
  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(String(value)) + " | wl-copy"])
  }

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/omaglass"

  function applyThemeFile(raw) {
    try {
      var parsed = JSON.parse(raw)
      if (parsed && typeof parsed.theme === "string" && Themes.exists(parsed.theme))
        root.themeId = parsed.theme
      if (parsed && typeof parsed.barMonotone === "boolean")
        root.barMonotone = parsed.barMonotone
    } catch (e) {
      // No saved settings yet -- keep the defaults.
    }
  }

  FileView {
    id: themeFile
    path: root.stateDir + "/theme.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyThemeFile(text())
    onLoadFailed: root.applyThemeFile("")
  }

  // Writes via a freshly-created, randomly-named temp file in the same
  // directory (mktemp's O_CREAT|O_EXCL semantics -- never following an
  // existing name) and then an atomic rename() over the real path, rather
  // than a plain `>` redirect to a predictable filename. `>` truncates and
  // writes through whatever is *already* at that path, symlink included --
  // a symlink or FIFO planted there ahead of time would redirect the write
  // or block it; an atomic rename replaces the directory entry itself
  // instead. The directory and temp file are both created privately
  // (0700/0600) rather than at the process's ambient umask.
  Process {
    id: themeWriteProc
    property string themeIdArg: ""
    property string monotoneArg: "true"
    command: ["bash", "-c", `
      DIR="$1"
      mkdir -p -m 0700 "$DIR" || exit 1
      umask 077
      tmp=$(mktemp "$DIR/.theme.json.XXXXXX") || exit 1
      printf '{"theme":"%s","barMonotone":%s}' "$2" "$3" > "$tmp"
      chmod 0600 "$tmp"
      mv -f "$tmp" "$DIR/theme.json"
    `, "_", root.stateDir, themeIdArg, monotoneArg]
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

.pragma library

// Parses the tab-separated `key\tvalue` lines produced by
// `omarchy-network-status --verbose` into a plain object.
function parseStatus(raw) {
  var result = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var tab = line.indexOf("\t")
    if (tab < 0) continue
    result[line.substring(0, tab)] = line.substring(tab + 1)
  }
  return result
}

function toNumber(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function formatBytes(bytes) {
  var b = Number(bytes)
  if (!isFinite(b) || b < 0) b = 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  var v = b
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  var decimals = (i > 0 && v < 10) ? 1 : 0
  return v.toFixed(decimals) + " " + units[i]
}

function formatRate(bytesPerSecond) {
  return formatBytes(bytesPerSecond) + "/s"
}

// -- `ss -tup` parsing -------------------------------------------------------

function splitAddrPort(s) {
  s = String(s || "")
  if (s.charAt(0) === "[") {
    var end = s.indexOf("]")
    if (end < 0) return { addr: s, port: "" }
    return { addr: s.substring(1, end), port: s.substring(end + 2) }
  }
  var idx = s.lastIndexOf(":")
  if (idx < 0) return { addr: s, port: "" }
  return { addr: s.substring(0, idx), port: s.substring(idx + 1) }
}

// One row per active socket with a real peer: process name (when the socket
// is owned by us), protocol, local port, and remote address/port. No
// per-connection byte counts -- `ss` doesn't expose those without root, and
// this doesn't invent numbers.
function parseConnections(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.indexOf("Netid") === 0) continue
    var cols = line.split(/\s+/)
    if (cols.length < 6) continue
    var netid = cols[0]
    var state = cols[1]
    if (state === "LISTEN" || state === "UNCONN") continue
    var local = splitAddrPort(cols[4])
    var peer = splitAddrPort(cols[5])
    if (!peer.addr || peer.addr === "*" || peer.addr === "0.0.0.0" || peer.addr === "::") continue
    var rest = cols.slice(6).join(" ")
    var procMatch = rest.match(/\(\("([^"]+)",pid=(\d+)/)
    out.push({
      protocol: netid,
      state: state,
      localPort: local.port,
      remoteIp: peer.addr,
      remotePort: peer.port,
      process: procMatch ? procMatch[1] : "",
      pid: procMatch ? procMatch[2] : ""
    })
  }
  out.sort(function(a, b) {
    var an = a.process || "￿"
    var bn = b.process || "￿"
    return an === bn ? 0 : (an < bn ? -1 : 1)
  })
  return out
}

// Nests the flat connection list under one header row per process, instead
// of repeating "chromium" on every single one of its dozen sockets. Already
// sorted alphabetically by parseConnections, so grouping by run of matching
// process is enough -- no need to re-sort.
function groupConnectionsByProcess(connections) {
  var order = []
  // Object.create(null): `key` comes from a process name string parsed out
  // of `ss` output, so a process legitimately (or maliciously) named
  // e.g. "__proto__" must not collide with Object.prototype.
  var groups = Object.create(null)
  for (var i = 0; i < connections.length; i++) {
    var c = connections[i]
    var key = c.process || "Unknown"
    if (!groups[key]) {
      groups[key] = []
      order.push(key)
    }
    groups[key].push(c)
  }
  var out = []
  for (var j = 0; j < order.length; j++) {
    out.push({ process: order[j], items: groups[order[j]] })
  }
  return out
}

// -- `ip neigh show` parsing --------------------------------------------------

function parseNeighbors(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var m = line.match(/^(\S+)\s+dev\s+(\S+)(?:\s+lladdr\s+(\S+))?\s+(\S+)$/)
    if (!m) continue
    out.push({ ip: m[1], iface: m[2], mac: m[3] || "", state: m[4] })
  }
  return out
}

// -- IP helpers ---------------------------------------------------------------

// Whether an address is non-global -- private, loopback, link-local,
// documentation/test, multicast, or otherwise not something that should
// ever be disclosed to a third-party lookup service. Deliberately
// conservative: anything malformed or not recognized as a normal global
// unicast address is treated as private (fails closed), since the only
// consequence of a false positive here is skipping a GeoIP/whois lookup,
// while a false negative would leak a non-routable address externally.
function isPrivateIp(ip) {
  var s = String(ip || "").trim()
  if (!s) return true
  if (s === "127.0.0.1" || s === "::1" || s === "::" || s === "localhost") return true

  if (s.indexOf(":") !== -1) {
    var lower = s.toLowerCase()
    // IPv4-mapped IPv6 (::ffff:a.b.c.d) -- re-check the embedded IPv4.
    var mapped = lower.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/)
    if (mapped) return isPrivateIp(mapped[1])
    if (lower.indexOf("fe80:") === 0) return true // link-local, fe80::/10 (practical form)
    if (lower.indexOf("fc") === 0 || lower.indexOf("fd") === 0) return true // unique local, fc00::/7
    if (lower.indexOf("ff") === 0) return true // multicast, ff00::/8
    if (lower.indexOf("2001:db8") === 0) return true // documentation, 2001:db8::/32
    if (lower.indexOf("::") === 0 && lower !== "::") return true // catches any other all-zero-prefixed edge case conservatively
    return false
  }

  var parts = s.split(".")
  if (parts.length !== 4) return true
  var a = Number(parts[0])
  var b = Number(parts[1])
  var c = Number(parts[2])
  if (!isFinite(a) || !isFinite(b) || !isFinite(c) || a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255) return true
  if (a === 0) return true // "this network", 0.0.0.0/8
  if (a === 10) return true // RFC1918, 10/8
  if (a === 100 && b >= 64 && b <= 127) return true // CGNAT, 100.64/10
  if (a === 127) return true // loopback, 127/8
  if (a === 169 && b === 254) return true // link-local, 169.254/16
  if (a === 172 && b >= 16 && b <= 31) return true // RFC1918, 172.16/12
  if (a === 192 && b === 0 && c === 0) return true // IETF protocol assignments, 192.0.0/24
  if (a === 192 && b === 0 && c === 2) return true // TEST-NET-1, 192.0.2/24
  if (a === 192 && b === 168) return true // RFC1918, 192.168/16
  if (a === 198 && (b === 18 || b === 19)) return true // benchmarking, 198.18/15
  if (a === 198 && b === 51 && c === 100) return true // TEST-NET-2, 198.51.100/24
  if (a === 203 && b === 0 && c === 113) return true // TEST-NET-3, 203.0.113/24
  if (a >= 224) return true // multicast (224/4) + reserved/future (240/4) + broadcast
  return false
}

// A-Z regional indicator symbols compose into a flag emoji for a two-letter
// ISO country code. Renders as a picture with a color-emoji font installed;
// degrades gracefully to two boxes otherwise, so callers also show the code.
function countryFlagEmoji(code) {
  var cc = String(code || "").toUpperCase()
  if (cc.length !== 2) return ""
  var c0 = cc.charCodeAt(0)
  var c1 = cc.charCodeAt(1)
  if (c0 < 65 || c0 > 90 || c1 < 65 || c1 > 90) return ""
  return String.fromCodePoint(0x1F1E6 + (c0 - 65)) + String.fromCodePoint(0x1F1E6 + (c1 - 65))
}

// -- ipwho.is response parsing -------------------------------------------------
//
// One IP looked up per call (see Panel.qml's geo lookup queue) rather than a
// batch, so this only ever needs to pick two fixed, known property names off
// one parsed object -- no dynamic keys, so there's no map to defend against
// a hostile `__proto__`-shaped payload in the first place.

function parseGeoSingle(raw) {
  try {
    var item = JSON.parse(raw)
    if (!item || item.success !== true) return null
    return {
      countryCode: String(item.country_code || ""),
      country: String(item.country || "")
    }
  } catch (e) {
    return null
  }
}

// -- `ss -tiepn` parsing (TCP, extended info, process, numeric ports) --------
//
// Same idea as parseConnections, but paired with the indented "extended
// info" line ss prints under each TCP socket, which carries this kernel's
// actual bytes_sent/bytes_received counters for that connection (cumulative
// since it opened) -- the one piece of real, non-fabricated byte-volume data
// available without root. UDP sockets don't carry this (no tcp_info), so
// they're absent from usage totals -- not zeroed out, just not counted.
function parseConnectionsExtended(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  var i = 0
  while (i < lines.length) {
    var line = lines[i]
    var trimmed = line.replace(/^\s+|\s+$/g, "")
    if (!trimmed || trimmed.indexOf("State") === 0 || line.charAt(0) === "\t" || line.charAt(0) === " ") {
      i++
      continue
    }
    var cols = trimmed.split(/\s+/)
    i++
    if (cols.length < 5) continue
    var state = cols[0]
    var local = splitAddrPort(cols[3])
    var peer = splitAddrPort(cols[4])
    var rest = cols.slice(5).join(" ")
    var procMatch = rest.match(/\(\("([^"]+)",pid=(\d+)/)

    var bytesSent = 0
    var bytesReceived = 0
    if (i < lines.length && (lines[i].charAt(0) === "\t" || lines[i].charAt(0) === " ")) {
      var infoLine = lines[i]
      var sentMatch = infoLine.match(/bytes_sent:(\d+)/)
      var recvMatch = infoLine.match(/bytes_received:(\d+)/)
      if (sentMatch) bytesSent = Number(sentMatch[1])
      if (recvMatch) bytesReceived = Number(recvMatch[1])
      i++
    }

    if (state === "LISTEN") continue
    if (!peer.addr || peer.addr === "*" || peer.addr === "0.0.0.0" || peer.addr === "::") continue

    out.push({
      state: state,
      localPort: local.port,
      remoteIp: peer.addr,
      remotePort: peer.port,
      process: procMatch ? procMatch[1] : "",
      bytesSent: bytesSent,
      bytesReceived: bytesReceived
    })
  }
  return out
}

// Well-known port -> friendly service name, for the "Traffic Type" grouping.
// Falls back to a plain port label for anything not in the table.
var SERVICE_NAMES = {
  20: "FTP Data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP",
  53: "DNS", 67: "DHCP", 68: "DHCP", 69: "TFTP", 80: "HTTP",
  110: "POP3", 119: "NNTP", 123: "NTP", 135: "MS RPC",
  137: "NetBIOS Name Service", 138: "NetBIOS Datagram", 139: "NetBIOS Session",
  143: "IMAP", 161: "SNMP", 162: "SNMP Trap", 179: "BGP",
  389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS",
  546: "DHCPv6 Client", 547: "DHCPv6 Server", 587: "SMTP Submission",
  636: "LDAPS", 853: "DNS over TLS", 993: "IMAPS", 995: "POP3S",
  1900: "SSDP", 3306: "MySQL", 3389: "RDP", 5222: "XMPP",
  5353: "Multicast DNS", 5432: "PostgreSQL", 6379: "Redis",
  8080: "HTTP Alt", 8443: "HTTPS Alt", 27017: "MongoDB", 51820: "WireGuard"
}

function serviceName(port) {
  var p = Number(port)
  if (isFinite(p) && SERVICE_NAMES[p]) return SERVICE_NAMES[p]
  return "Port " + port
}

// Generic "sum bytes by key" reducer used for the Usage tab's four
// breakdowns (app / host / traffic type / country). Returns entries sorted
// by bytes descending, each with its share of the total for proportional
// bars.
function aggregateBytes(list, keyFn) {
  // Object.create(null): keys here can be reverse-DNS hostnames or process
  // names -- both are strings an attacker on the other end of a connection
  // has some influence over (a PTR record, a process's own argv[0]), so a
  // plain {} would let a key like "__proto__" collide with Object.prototype.
  var totals = Object.create(null)
  var totalBytes = 0
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    var bytes = (Number(item.bytesSent) || 0) + (Number(item.bytesReceived) || 0)
    var key = keyFn(item)
    if (!key) continue
    totals[key] = (totals[key] || 0) + bytes
    totalBytes += bytes
  }
  var out = []
  for (var k in totals) out.push({ label: k, bytes: totals[k] })
  out.sort(function(a, b) { return b.bytes - a.bytes })
  for (var j = 0; j < out.length; j++)
    out[j].share = totalBytes > 0 ? out[j].bytes / totalBytes : 0
  return out
}

// -- reverse DNS (`getent hosts <ip>`) ---------------------------------------

function parseGetentHost(raw) {
  var line = String(raw || "").trim().split("\n")[0]
  if (!line) return ""
  var parts = line.split(/\s+/)
  return parts.length >= 2 ? parts[parts.length - 1] : ""
}

// -- whois -------------------------------------------------------------------

// Strips comment/banner lines (RIPE-style `%`, ARIN-style `#`) and caps
// length so a registry's full legal boilerplate doesn't blow out the popup.
function formatWhois(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\s+$/, "")
    if (line === "") continue
    if (line.charAt(0) === "%" || line.charAt(0) === "#") continue
    out.push(line)
    if (out.length >= 40) break
  }
  if (out.length === 0) return "No whois data returned."
  return out.join("\n")
}

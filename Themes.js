.pragma library

// Color themes for the traffic graph and gauges. Each entry names a WAN
// pair (download/upload) and a LAN pair (lanDownload/lanUpload) -- chosen
// to sit in a different part of the wheel from that theme's own WAN pair,
// so the two never blend together, while still fitting the theme's overall
// palette. "omarchy" is the default and is dynamic: all four colors are
// resolved live from the active Omarchy theme (see Panel.qml's lanDownColor
// / lanUpColor, which hue-rotate Color.accent / Color.urgent) rather than
// fixed here.
var THEMES = [
  { id: "omarchy", name: "Omarchy", dynamic: true },
  { id: "classic-blue", name: "Classic Blue", download: "#22d3ee", upload: "#8b5cf6", lanDownload: "#34d399", lanUpload: "#f59e0b" },
  { id: "graphite", name: "Graphite", download: "#e7e9ec", upload: "#7c8591", lanDownload: "#84cc16", lanUpload: "#fb923c" },
  { id: "emerald", name: "Emerald", download: "#34d399", upload: "#facc15", lanDownload: "#22d3ee", lanUpload: "#f472b6" },
  { id: "solarized", name: "Solarized", download: "#268bd2", upload: "#b58900", lanDownload: "#859900", lanUpload: "#dc322f" },
  { id: "sunset", name: "Sunset", download: "#fb923c", upload: "#f43f5e", lanDownload: "#22d3ee", lanUpload: "#a3e635" },
  { id: "purple-haze", name: "Purple Haze", download: "#c084fc", upload: "#f472b6", lanDownload: "#4ade80", lanUpload: "#facc15" }
]

function byId(id) {
  for (var i = 0; i < THEMES.length; i++) {
    if (THEMES[i].id === id) return THEMES[i]
  }
  return THEMES[0]
}

function exists(id) {
  for (var i = 0; i < THEMES.length; i++) {
    if (THEMES[i].id === id) return true
  }
  return false
}

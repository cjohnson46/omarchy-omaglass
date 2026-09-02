import QtQuick
import qs.Commons

// Smooth multi-series area/line graph: glowing, filled traffic curves, each
// scaled per its own scale group (see `scaleGroup`/`staticMax` below) and
// scrolling on its own clock (see `syncTick` below). Values are lightly
// smoothed before plotting and connected with a monotone cubic spline (not
// straight or overshoot-prone segments) for the rounded, flowing look real
// traffic monitors use, rather than a jagged trace of raw per-second
// samples. A continuous scroll animation eases the newest sample in from
// the right edge over the full second between polls instead of jumping
// into place.
//
// `series` is a plain array, drawn in order: [{ values, color, fillOpacity,
// glow, scaleGroup, staticMax, syncTick }, ...].
//   - scaleGroup: series sharing this string (default "default") share one
//     peak-based vertical scale, same as the original down/up pair; a
//     different group (e.g. "lan") gets its own scale, so a much
//     smaller-magnitude series isn't squashed flat by a larger one's peak.
//   - staticMax: set this to opt a series OUT of peak-based auto-scaling
//     entirely -- its scale is exactly this fixed number, always, useful
//     for a secondary series that's meant to read as calm/stable rather
//     than zooming with every fluctuation.
//   - syncTick: bump this counter each time the caller lands a real sample
//     for that series. Each series scrolls on its OWN clock, reset only
//     when ITS tick changes -- essential once more than one series comes
//     from independent async sources (e.g. WAN from one process, LAN from
//     another): sharing one clock meant it reset however many times the
//     two happened to land apart within a second, which read as jutter.
// Passing `series` as one array (rather than separate properties per line)
// means every input changing together lands as one atomic property write.
//
// The expensive part -- smoothing each series and fitting its spline --
// only runs when the data actually changes (about once a second). Each
// animation frame just offsets the cached point/segment coordinates by the
// current scroll distance and redraws, so an animated frame costs a cheap
// remap plus a handful of draw calls, not a full recompute.
Canvas {
  id: root

  // Each entry: { values, color, fillOpacity, glow, scaleGroup, staticMax,
  // syncTick }. `syncTick` is the key to smooth scrolling across
  // independently-sampled series: WAN and LAN land via two separate async
  // processes that don't complete at the same instant, and a single shared
  // scroll clock reset on "any series changed" meant the scroll restarted
  // however many times the two happened to land apart within a cycle --
  // smooth, snap, smooth-again, at irregular sub-second intervals. Instead,
  // each series carries its own counter from its own data source (bump it
  // once per real sample); this Canvas tracks a scroll clock PER SERIES,
  // resetting series i's clock only when series i's own syncTick changes.
  // A series whose syncTick is omitted just doesn't animate independently
  // (falls back to a shared default clock).
  property var series: []
  property bool liveAnimation: false
  property real samplePeriodMs: 1000
  // Set true to track the mouse and expose hoverIndex (which sample column
  // it's over) plus draw a subtle vertical guide line there. Off by
  // default -- the tiny bar icon has no use for it.
  property bool hoverable: false

  property real lastSampleTime: Date.now() // fallback clock for untagged series
  property var seriesClocks: [] // per-series lastSampleTime, parallel to `series`
  property var prevSyncTicks: [] // per-series previous syncTick, to detect a real change
  property var seriesCache: [] // parallel to `series`: [{points, segments}, ...]

  // Which sample column the mouse is currently over, -1 when not hovering.
  // A caller reads this (plus the same index into its own data arrays) to
  // build a tooltip; this component only tracks the index and draws the
  // guide line, it doesn't know what the values mean.
  property int hoverIndex: -1
  readonly property int hoverSampleCount: {
    var n = 0
    for (var k = 0; k < seriesCache.length; k++) n = Math.max(n, seriesCache[k].points.length)
    return n
  }

  antialiasing: true

  MouseArea {
    anchors.fill: parent
    enabled: root.hoverable
    hoverEnabled: root.hoverable
    acceptedButtons: Qt.NoButton
    onExited: { root.hoverIndex = -1; root.requestPaint() }
    onPositionChanged: function(mouse) {
      var n = root.hoverSampleCount
      if (n < 2) { root.hoverIndex = -1; return }
      var step = root.width / (n - 1)
      var idx = Math.round(mouse.x / step)
      root.hoverIndex = Math.max(0, Math.min(n - 1, idx))
      root.requestPaint()
    }
  }

  property bool rebuildQueued: false
  function scheduleRebuild() {
    if (rebuildQueued) return
    rebuildQueued = true
    Qt.callLater(function() {
      root.rebuildQueued = false
      root.updateClocks()
      root.rebuild()
      root.requestPaint()
    })
  }

  // Atomic with the geometry rebuild: a series' clock resets in the exact
  // same pass that its new points are computed, so the array-reindex and
  // the clock-reset that need to cancel each other out for a seamless
  // scroll always happen together, per series.
  function updateClocks() {
    var now = Date.now()
    var newClocks = new Array(series.length)
    var newTicks = new Array(series.length)
    for (var i = 0; i < series.length; i++) {
      var tick = series[i].syncTick
      newTicks[i] = tick
      var hasTick = tick !== undefined
      var prevTick = i < prevSyncTicks.length ? prevSyncTicks[i] : undefined
      var prevClock = i < seriesClocks.length ? seriesClocks[i] : undefined
      if (!hasTick) {
        newClocks[i] = root.lastSampleTime
      } else if (prevClock === undefined || tick !== prevTick) {
        newClocks[i] = now
      } else {
        newClocks[i] = prevClock
      }
    }
    seriesClocks = newClocks
    prevSyncTicks = newTicks
  }

  onSeriesChanged: scheduleRebuild()
  onWidthChanged: scheduleRebuild()
  onHeightChanged: scheduleRebuild()

  // Canvas repaint has real fixed cost per call (CPU rasterization + a
  // texture upload), independent of point count -- so the frame rate here
  // is chosen to be smooth for a slow, continuous scroll (not 60fps-smooth
  // motion) while keeping an always-visible bar icon cheap to animate.
  property int animationIntervalMs: 33

  Timer {
    interval: root.animationIntervalMs
    running: root.liveAnimation && root.visible
    repeat: true
    onTriggered: root.requestPaint()
  }

  // Light 3-tap moving average on the raw per-second samples. Real traffic
  // is bursty at 1s resolution -- this rounds single-sample spikes into the
  // gentle rolling hills a smooth spline can actually show off, rather than
  // a perfectly sharp spike with a rounded pen. Endpoints are left alone so
  // the series doesn't dull the current/oldest edge values.
  function smoothSeries(values) {
    var n = values.length
    if (n < 3) return values.slice()
    var out = new Array(n)
    out[0] = values[0]
    out[n - 1] = values[n - 1]
    for (var i = 1; i < n - 1; i++) {
      out[i] = Number(values[i - 1]) * 0.25 + Number(values[i]) * 0.5 + Number(values[i + 1]) * 0.25
    }
    return out
  }

  function seriesMax(values) {
    var m = 0
    for (var i = 0; i < values.length; i++) {
      var v = Number(values[i])
      if (isFinite(v) && v > m) m = v
    }
    return m
  }

  // 0..maxVal scale, maxVal supplied per call (see rebuild -- it's the peak
  // of whichever series share this one's scaleGroup, with 45% headroom so
  // the peak itself doesn't touch the top).
  //
  // Not a straight v/maxVal ratio -- that pins anything below roughly a
  // tenth of maxVal to a couple of flat pixels at the very bottom, which on
  // a megabyte-scale ceiling means ordinary background chatter (DNS
  // queries, keepalives, tens to hundreds of bytes/sec) never visibly
  // moves the line at all. Raising the ratio to a small power pulls that
  // low end up into visible motion while values already near the ceiling
  // still read close to full height. 0.16 (paired with the WAN graph's
  // 32 MB/s ceiling) keeps that same ~100 B/s sliver of motion at the
  // bottom, while still giving real, order-of-magnitude differences in
  // traffic a proportional difference in height -- a trickle and a real
  // multi-megabyte burst no longer read as roughly the same "high".
  readonly property real curveExponent: 0.16

  function buildPoints(values, maxVal) {
    var pts = []
    var n = values.length
    var step = n > 1 ? width / (n - 1) : width
    var mv = maxVal > 0 ? maxVal : 1
    for (var i = 0; i < n; i++) {
      var v = Math.max(0, Number(values[i]) || 0)
      var lin = Math.max(0, Math.min(1, v / mv))
      var norm = lin > 0 ? Math.pow(lin, root.curveExponent) : 0
      var x = n > 1 ? i * step : width
      var y = height - norm * Math.max(1, height - 2) - 1
      pts.push({ x: x, y: y })
    }
    return pts
  }

  // Monotone cubic Hermite spline (Fritsch-Carlson), precomputed as a list
  // of bezier control points. Passes smoothly through every point without
  // overshooting past its neighbors' values -- a plain Catmull-Rom/cardinal
  // spline bulges past a sharp isolated spike, which on a small canvas with
  // limited headroom clips against the top edge into an ugly flat-topped
  // shape. Monotone interpolation is what real charting libraries use for
  // exactly this reason: rounded peaks, no overshoot.
  function computeSegments(points) {
    var n = points.length
    if (n < 3) return []

    var d = new Array(n - 1)
    for (var i = 0; i < n - 1; i++) {
      var dx = points[i + 1].x - points[i].x
      d[i] = dx !== 0 ? (points[i + 1].y - points[i].y) / dx : 0
    }

    var m = new Array(n)
    m[0] = d[0]
    m[n - 1] = d[n - 2]
    for (var i2 = 1; i2 < n - 1; i2++) {
      if (d[i2 - 1] === 0 || d[i2] === 0 || (d[i2 - 1] > 0) !== (d[i2] > 0)) m[i2] = 0
      else m[i2] = (d[i2 - 1] + d[i2]) / 2
    }

    // Fritsch-Carlson tangent clamp per segment, so the curve never swings
    // past either endpoint's value.
    for (var i3 = 0; i3 < n - 1; i3++) {
      if (d[i3] === 0) {
        m[i3] = 0
        m[i3 + 1] = 0
        continue
      }
      var a = m[i3] / d[i3]
      var b = m[i3 + 1] / d[i3]
      if (a < 0) m[i3] = 0
      if (b < 0) m[i3 + 1] = 0
      var s = a * a + b * b
      if (s > 9) {
        var tau = 3 / Math.sqrt(s)
        m[i3] = tau * a * d[i3]
        m[i3 + 1] = tau * b * d[i3]
      }
    }

    var segments = new Array(n - 1)
    for (var i4 = 0; i4 < n - 1; i4++) {
      var p0 = points[i4]
      var p1 = points[i4 + 1]
      var third = (p1.x - p0.x) / 3
      segments[i4] = {
        cp1x: p0.x + third,
        cp1y: p0.y + m[i4] * third,
        cp2x: p1.x - third,
        cp2y: p1.y - m[i4 + 1] * third,
        x: p1.x,
        y: p1.y
      }
    }
    return segments
  }

  // Per-frame animation offset, applied directly to coordinates rather than
  // via ctx.translate -- a plain dx addition on cached numbers is cheap
  // (this is the only work a mid-second animation frame does), and it
  // sidesteps any interaction between a canvas transform and gradient fills
  // on this Canvas backend.
  function shiftPoints(points, dx) {
    var out = new Array(points.length)
    for (var i = 0; i < points.length; i++) out[i] = { x: points[i].x + dx, y: points[i].y }
    return out
  }

  function shiftSegments(segments, dx) {
    var out = new Array(segments.length)
    for (var i = 0; i < segments.length; i++) {
      var s = segments[i]
      out[i] = { cp1x: s.cp1x + dx, cp1y: s.cp1y, cp2x: s.cp2x + dx, cp2y: s.cp2y, x: s.x + dx, y: s.y }
    }
    return out
  }

  // Appends the curve to whatever subpath is already open at points[0] --
  // does NOT move/start a new subpath itself. The fill boundary needs this:
  // it's already at points[0] (having just drawn the vertical edge up from
  // the baseline), and issuing another moveTo to that same coordinate before
  // continuing was leaving this Canvas backend's path builder in a state
  // where the following bezierCurveTo calls traced relative to the wrong
  // anchor -- the visible symptom was the fill's top edge collapsing into a
  // single straight line from the first point to the last, while the
  // separately-stroked curve (which never had a redundant moveTo) rendered
  // correctly. Two calls to fill vs. stroke ending up with different
  // geometry was the actual bug, not a color/opacity issue.
  function traceCurve(ctx, points, segments) {
    if (points.length === 2) {
      ctx.lineTo(points[1].x, points[1].y)
      return
    }
    for (var i = 0; i < segments.length; i++) {
      var s = segments[i]
      ctx.bezierCurveTo(s.cp1x, s.cp1y, s.cp2x, s.cp2y, s.x, s.y)
    }
  }

  // Starts a fresh subpath at points[0] and traces the curve -- for the
  // standalone stroke passes, which don't already have a subpath open.
  function tracePath(ctx, points, segments) {
    if (points.length === 0) return
    ctx.moveTo(points[0].x, points[0].y)
    traceCurve(ctx, points, segments)
  }

  // Recomputes point positions and the spline fit for every series. Only
  // called when the data, scale, or canvas size actually change -- not
  // every animation frame.
  function rebuild() {
    if (width <= 0 || height <= 0) return

    // A series with `staticMax` set opts out of auto-scaling entirely --
    // its scale is that fixed number, full stop, never computed from peaks.
    // Groups made only of auto-scaled series still share one peak-based max
    // the way the original down/up pair always did.
    var smoothedList = new Array(series.length)
    var groupPeak = {}
    for (var i = 0; i < series.length; i++) {
      smoothedList[i] = smoothSeries(series[i].values || [])
      if (series[i].staticMax !== undefined) continue
      var group = series[i].scaleGroup || "default"
      var peak = seriesMax(smoothedList[i])
      if (!(group in groupPeak) || peak > groupPeak[group]) groupPeak[group] = peak
    }

    var cache = []
    for (var j = 0; j < series.length; j++) {
      var maxVal
      if (series[j].staticMax !== undefined) {
        maxVal = series[j].staticMax
      } else {
        var g = series[j].scaleGroup || "default"
        maxVal = (groupPeak[g] || 0) * 1.45
      }
      var pts = buildPoints(smoothedList[j], maxVal)
      cache.push({ points: pts, segments: computeSegments(pts) })
    }
    seriesCache = cache
  }

  function drawSeries(ctx, points, segments, color, fillOpacity, glow) {
    if (points.length === 0) return

    ctx.beginPath()
    ctx.moveTo(points[0].x, height)
    ctx.lineTo(points[0].x, points[0].y)
    traceCurve(ctx, points, segments)
    ctx.lineTo(points[points.length - 1].x, height)
    ctx.closePath()
    // Bold near-solid color at the top (close to the line's own color, not
    // a washed-out tint), carried most of the way down before it fades, so
    // the fill reads as a real presence under the curve rather than a thin
    // highlight.
    var gradient = ctx.createLinearGradient(0, 0, 0, height)
    gradient.addColorStop(0, Util.alpha(color, Math.min(0.92, fillOpacity + 0.2)))
    gradient.addColorStop(0.75, Util.alpha(color, fillOpacity * 0.6))
    gradient.addColorStop(1, Util.alpha(color, fillOpacity * 0.22))
    ctx.fillStyle = gradient
    ctx.fill()

    if (glow) {
      ctx.beginPath()
      tracePath(ctx, points, segments)
      ctx.strokeStyle = Util.alpha(color, 0.35)
      ctx.lineWidth = Style.spaceReal(4)
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.stroke()
    }

    ctx.beginPath()
    tracePath(ctx, points, segments)
    ctx.strokeStyle = color
    ctx.lineWidth = Math.max(1, Style.spaceReal(1.5))
    ctx.lineJoin = "round"
    ctx.lineCap = "round"
    ctx.stroke()
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    if (width <= 0 || height <= 0 || seriesCache.length === 0) return

    var now = Date.now()

    for (var i = 0; i < series.length && i < seriesCache.length; i++) {
      var s = series[i]
      var c = seriesCache[i]
      var n = c.points.length
      var step = n > 1 ? width / (n - 1) : 0
      var clock = i < seriesClocks.length ? seriesClocks[i] : root.lastSampleTime
      var progress = root.liveAnimation
        ? Math.max(0, Math.min(1, (now - clock) / root.samplePeriodMs))
        : 1
      // The newest sample lands at the right edge (shiftX 0) and glides
      // left by exactly one sample-spacing over the second, so it comes to
      // rest right where the next sample will land -- a continuous scroll
      // with no snap at the second boundary. Each series uses its OWN
      // clock, so WAN and LAN scroll independently and correctly even
      // though their data arrives at different real moments.
      var shiftX = n > 1 ? -step * progress : 0
      var pts = shiftX !== 0 ? shiftPoints(c.points, shiftX) : c.points
      var segs = shiftX !== 0 ? shiftSegments(c.segments, shiftX) : c.segments
      var fillOpacity = s.fillOpacity !== undefined ? s.fillOpacity : 0.6
      var glow = s.glow !== false
      drawSeries(ctx, pts, segs, s.color, fillOpacity, glow)
    }

    // Guide line at the hovered column, in raw (unshifted) sample space --
    // matches exactly how the MouseArea above turned mouse.x into
    // hoverIndex, so the line always sits directly under the cursor.
    if (root.hoverable && root.hoverIndex >= 0 && root.hoverSampleCount > 1) {
      var hoverStep = width / (root.hoverSampleCount - 1)
      var hoverX = root.hoverIndex * hoverStep
      ctx.beginPath()
      ctx.moveTo(hoverX, 0)
      ctx.lineTo(hoverX, height)
      ctx.strokeStyle = Util.alpha(Color.popups.text, 0.25)
      ctx.lineWidth = 1
      ctx.stroke()
    }
  }
}

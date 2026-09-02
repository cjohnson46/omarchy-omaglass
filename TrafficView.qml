import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root
  required property var panel
  width: parent.width
  spacing: Style.space(14)

  Row {
    spacing: Style.space(28)
    anchors.horizontalCenter: parent.horizontalCenter

    Gauge {
      value: panel.downRate
      valueText: panel.downRateText
      label: "DOWNLOAD"
      gaugeColor: panel.downColor
    }
    Gauge {
      value: panel.upRate
      valueText: panel.upRateText
      label: "UPLOAD"
      gaugeColor: panel.upColor
    }
  }

  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(8)

    Repeater {
      model: [
        { key: 30, label: "30s" },
        { key: 120, label: "2m" },
        { key: 600, label: "10m" },
        { key: 1800, label: "30m" }
      ]

      Rectangle {
        required property var modelData
        readonly property bool active: panel.historyWindowSeconds === modelData.key
        width: Style.space(46)
        height: Style.space(24)
        radius: Style.space(12)
        color: active
          ? Util.alpha(Color.accent, 0.22)
          : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.06)
        border.width: active ? 1 : 0
        border.color: Color.accent

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: modelData.label
          color: active ? Color.popups.text : panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: panel.historyWindowSeconds = modelData.key
        }
      }
    }
  }

  BorderSurface {
    id: graphBox
    width: parent.width
    height: Style.space(190)
    radius: Style.cornerRadius
    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.04)
    borderSpec: Border.flat(Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10), 1)

    // Freezes what this graph displays and animates, without touching
    // background sampling -- Usage/Peak/Session stats keep updating live
    // even while paused, so a burst of traffic can be inspected without it
    // scrolling away in the meantime.
    property bool paused: false
    property var frozen: null

    function togglePause() {
      if (!graphBox.paused) {
        graphBox.frozen = {
          down: panel.windowedDownHistory.slice(),
          up: panel.windowedUpHistory.slice(),
          lanDown: panel.windowedLanDownHistory.slice(),
          lanUp: panel.windowedLanUpHistory.slice(),
          downOverscan: panel.windowedDownOverscan.slice(),
          upOverscan: panel.windowedUpOverscan.slice(),
          lanDownOverscan: panel.windowedLanDownOverscan.slice(),
          lanUpOverscan: panel.windowedLanUpOverscan.slice(),
          syncTick: panel.syncTick,
          lanSyncTick: panel.lanSyncTick
        }
        graphBox.paused = true
      } else {
        graphBox.paused = false
        graphBox.frozen = null
      }
    }

    readonly property var displayDown: graphBox.paused && graphBox.frozen ? graphBox.frozen.down : panel.windowedDownHistory
    readonly property var displayUp: graphBox.paused && graphBox.frozen ? graphBox.frozen.up : panel.windowedUpHistory
    readonly property var displayLanDown: graphBox.paused && graphBox.frozen ? graphBox.frozen.lanDown : panel.windowedLanDownHistory
    readonly property var displayLanUp: graphBox.paused && graphBox.frozen ? graphBox.frozen.lanUp : panel.windowedLanUpHistory
    readonly property var displayDownOverscan: graphBox.paused && graphBox.frozen ? graphBox.frozen.downOverscan : panel.windowedDownOverscan
    readonly property var displayUpOverscan: graphBox.paused && graphBox.frozen ? graphBox.frozen.upOverscan : panel.windowedUpOverscan
    readonly property var displayLanDownOverscan: graphBox.paused && graphBox.frozen ? graphBox.frozen.lanDownOverscan : panel.windowedLanDownOverscan
    readonly property var displayLanUpOverscan: graphBox.paused && graphBox.frozen ? graphBox.frozen.lanUpOverscan : panel.windowedLanUpOverscan
    readonly property int displaySyncTick: graphBox.paused && graphBox.frozen ? graphBox.frozen.syncTick : panel.syncTick
    readonly property int displayLanSyncTick: graphBox.paused && graphBox.frozen ? graphBox.frozen.lanSyncTick : panel.lanSyncTick

    BandwidthGraph {
      id: graph
      anchors.fill: parent
      anchors.margins: Style.space(10)
      hoverable: true
      // LAN drawn first (behind, thinner, no glow) so the WAN pair stays
      // the visually primary reading on top of it. Every series here uses
      // a fixed staticMax -- genuinely static, not auto-scaled to a peak at
      // all. Peak-based scaling has a real problem: when a big spike ages
      // out of the visible window, the scale recomputes smaller, and every
      // remaining (unchanged) value visually jumps taller since it now
      // fills a bigger fraction of a shrunken range -- values that never
      // moved look like they grew. A fixed scale never does that; the same
      // byte rate always draws at the same height, full stop. WAN's ceiling
      // is 32 MB/s -- high enough that a genuinely big burst (tens of
      // MB/s) still has real headroom above everyday traffic instead of
      // pinning to the same near-max height as it, while BandwidthGraph's
      // curveExponent still pulls quiet background chatter up into visible
      // motion at the bottom end. WAN and LAN get different fixed ceilings
      // since their typical magnitudes differ by orders of magnitude. Each
      // series carries its own syncTick (see BandwidthGraph's header
      // comment) so WAN and LAN, arriving from two independent async
      // samples, each scroll smoothly on their own clock.
      series: [
        { values: graphBox.displayLanDown, overscanValues: graphBox.displayLanDownOverscan, color: panel.lanDownColor, fillOpacity: 0.32, glow: false, staticMax: 40000, syncTick: graphBox.displayLanSyncTick, slotShift: panel.lanSlotShift },
        { values: graphBox.displayLanUp, overscanValues: graphBox.displayLanUpOverscan, color: panel.lanUpColor, fillOpacity: 0.28, glow: false, staticMax: 40000, syncTick: graphBox.displayLanSyncTick, slotShift: panel.lanSlotShift },
        { values: graphBox.displayDown, overscanValues: graphBox.displayDownOverscan, color: panel.downColor, fillOpacity: 0.66, glow: true, staticMax: 32000000, syncTick: graphBox.displaySyncTick, slotShift: panel.wanSlotShift },
        { values: graphBox.displayUp, overscanValues: graphBox.displayUpOverscan, color: panel.upColor, fillOpacity: 0.55, glow: true, staticMax: 32000000, syncTick: graphBox.displaySyncTick, slotShift: panel.wanSlotShift }
      ]
      // Bound to the panel's real open state (and not paused), not just
      // this Canvas's own `visible` -- that stays true even while the
      // popup window itself is hidden, which left the animation timer (and
      // its per-frame spline recompute over the full windowed history)
      // running in the background indefinitely after close.
      liveAnimation: panel.opened && !graphBox.paused
      // A much bigger canvas than the bar icon (more pixels to rasterize
      // per repaint) with twice the series now (WAN + LAN) measured at a
      // real, non-trivial CPU cost at the default 30fps. 20fps reads just
      // as smooth for this kind of slow linear scroll and costs noticeably
      // less -- and this only runs at all while the popup is actually open.
      animationIntervalMs: 50
    }

    // Hover tooltip: follows the mouse column (graph.hoverIndex, from the
    // MouseArea inside BandwidthGraph) and reads the same index out of the
    // four raw windowed history arrays the graph itself plots (frozen ones
    // while paused), so the numbers shown always match the line under the
    // cursor.
    Rectangle {
      id: tooltip
      visible: graph.hoverIndex >= 0 && graph.hoverSampleCount > 1
      width: tooltipContent.implicitWidth + Style.space(16)
      height: tooltipContent.implicitHeight + Style.space(12)
      radius: Style.space(6)
      color: Qt.rgba(0, 0, 0, 0.78)
      border.width: 1
      border.color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.15)
      x: {
        var step = graph.width / Math.max(1, graph.hoverSampleCount - 1)
        var hx = graph.x + graph.hoverIndex * step
        return Math.max(4, Math.min(parent.width - width - 4, hx - width / 2))
      }
      y: graph.y + Style.space(4)

      Column {
        id: tooltipContent
        anchors.centerIn: parent
        spacing: Style.space(2)

        Repeater {
          model: [
            { label: "WAN ↓", tint: panel.downColor, value: Model.formatRate(graphBox.displayDown[graph.hoverIndex] || 0) },
            { label: "WAN ↑", tint: panel.upColor, value: Model.formatRate(graphBox.displayUp[graph.hoverIndex] || 0) },
            { label: "LAN ↓", tint: panel.lanDownColor, value: Model.formatRate(graphBox.displayLanDown[graph.hoverIndex] || 0) },
            { label: "LAN ↑", tint: panel.lanUpColor, value: Model.formatRate(graphBox.displayLanUp[graph.hoverIndex] || 0) }
          ]

          Row {
            required property var modelData
            spacing: Style.space(6)

            Rectangle {
              width: Style.space(7)
              height: Style.space(7)
              radius: Style.space(3.5)
              anchors.verticalCenter: parent.verticalCenter
              color: modelData.tint
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: "#c8c8c8"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              width: Style.space(34)
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.value
              color: "#ffffff"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }
    }

    // Pause/resume the graph: a bare icon (no button chrome), faint like
    // the rest of the secondary text, top-right corner out of the way of
    // the hover tooltip and the graph content itself.
    //
    // Hand-drawn rather than a "⏸"/"▶"/"‖" text character: every one of
    // those turned out to render as a fixed-color icon-font glyph on this
    // system (shows up orange, or as odd multi-color banding) that ignores
    // the `color` property entirely, and their differing natural widths
    // were also what made the two states land in different spots. A fixed
    // box with two plain shapes we color ourselves sidesteps both problems
    // and guarantees the play/pause states sit at the exact same spot.
    Item {
      id: pauseControl
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(10)
      width: Style.space(16)
      height: Style.space(16)

      readonly property color iconColor: pauseMouse.containsMouse ? Color.popups.text : panel.mutedText

      Row {
        visible: !graphBox.paused
        anchors.centerIn: parent
        spacing: Style.space(3)
        Rectangle { width: Style.space(3); height: Style.space(14); radius: 1; color: pauseControl.iconColor }
        Rectangle { width: Style.space(3); height: Style.space(14); radius: 1; color: pauseControl.iconColor }
      }

      Shape {
        id: playShape
        visible: graphBox.paused
        anchors.centerIn: parent
        width: Style.space(13)
        height: Style.space(15)
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          fillColor: pauseControl.iconColor
          strokeWidth: -1
          startX: 0; startY: 0
          PathLine { x: playShape.width; y: playShape.height / 2 }
          PathLine { x: 0; y: playShape.height }
          PathLine { x: 0; y: 0 }
        }
      }

      MouseArea {
        id: pauseMouse
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: graphBox.togglePause()
      }

      PanelToolTip {
        visible: pauseMouse.containsMouse
        text: graphBox.paused ? "Resume graph" : "Pause graph"
        fontFamily: Style.font.family
      }
    }
  }

  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(16)

    Repeater {
      model: [
        { label: "WAN ↓", tint: panel.downColor },
        { label: "WAN ↑", tint: panel.upColor },
        { label: "LAN ↓", tint: panel.lanDownColor },
        { label: "LAN ↑", tint: panel.lanUpColor }
      ]

      Row {
        required property var modelData
        spacing: Style.space(5)

        Rectangle {
          width: Style.space(8)
          height: Style.space(8)
          radius: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          color: modelData.tint
        }
        Text {
          textFormat: Text.PlainText
          text: modelData.label
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  Grid {
    width: parent.width
    columns: 4
    columnSpacing: Style.space(6)
    rowSpacing: Style.space(6)

    Repeater {
      model: [
        { title: "PEAK ↓", value: panel.peakDownText, tint: panel.downColor },
        { title: "PEAK ↑", value: panel.peakUpText, tint: panel.upColor },
        { title: "SESSION ↓", value: panel.sessionDownText, tint: panel.downColor },
        { title: "SESSION ↑", value: panel.sessionUpText, tint: panel.upColor }
      ]

      Column {
        required property var modelData
        width: (root.width - Style.space(18)) / 4
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: modelData.title
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          text: modelData.value
          color: modelData.tint
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }
    }
  }
}

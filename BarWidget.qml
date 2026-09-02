import QtQuick
import qs.Commons
import qs.Ui

// Bar icon: a small live traffic graph. A plain icon-slot button can't be
// widened past a square without also changing the icon's own aspect ratio,
// so this uses a custom WidgetButton sized explicitly (wider than tall) and
// nudges the graph up to sit on the same baseline as the neighboring glyph
// icons. Loads Panel.qml eagerly (same recipe as omarchy.weather) so it
// stays mounted as the single source of live sampling; this widget just
// visualizes it.
BarWidget {
  id: root
  moduleName: "io.github.cjohnson46.omaglass"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Width and height are deliberately decoupled: width is sized for
  // legibility (50% wider than a plain icon slot), but height stays close
  // to the neighboring glyphs' own ink height so the graph has real
  // clearance at both the top (peaks need headroom) and bottom (its
  // baseline needs to land on the same line the glyphs sit on) instead of
  // nearly filling the whole bar.
  readonly property real graphWidth: (Style.bar.iconCanvas + Style.space(6)) * 1.5
  readonly property real graphHeight: Style.bar.iconCanvas + Style.space(2)

  WidgetButton {
    id: button
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : root.graphWidth
    fixedHeight: root.vertical ? root.graphWidth : -1
    tooltipText: panelLoader.item
      ? ("↓ " + panelLoader.item.downRateText + "   ↑ " + panelLoader.item.upRateText)
      : "Network activity"

    onPressed: function(b) { root.togglePanel() }

    // Just the two WAN series here -- four overlapping fills in a ~35x18px
    // icon would be an unreadable smudge. The full breakdown (WAN + LAN)
    // is what the popup graph is for.
    //
    // liveAnimation is deliberately off: measured (disabled vs enabled,
    // A/B on this exact process) at ~20% of one core, continuously, for as
    // long as the shell is running -- Canvas repaint has real fixed cost
    // per call, and this icon is visible 100% of the time, unlike the
    // popup graph, which only animates while actually open. Static
    // (redraws once per real sample, no scroll interpolation between them)
    // is a small look downgrade for a small ambient indicator, in exchange
    // for taking this plugin's idle footprint from "constantly costs a
    // meaningful slice of a core" to "measures as zero."
    BandwidthGraph {
      width: root.graphWidth
      height: root.graphHeight
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: Style.space(2) - 3
      liveAnimation: false
      // Same fixed staticMax as the popup's WAN pair (see TrafficView), so
      // the two read consistently and neither jumps around as traffic
      // varies or a past spike ages out of view.
      series: panelLoader.item ? [
        { values: panelLoader.item.barDownHistory, color: panelLoader.item.barGraphDownColor, fillOpacity: 0.66, glow: false, staticMax: 32000000, syncTick: panelLoader.item.syncTick },
        { values: panelLoader.item.barUpHistory, color: panelLoader.item.barGraphUpColor, fillOpacity: 0.55, glow: false, staticMax: 32000000, syncTick: panelLoader.item.syncTick }
      ] : []
    }
  }
}

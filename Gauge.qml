import QtQuick
import QtQuick.Shapes
import qs.Commons

// Compact radial speed gauge: a 270° arc that fills toward an auto-expanding
// scale, with a glowing value arc and a digital readout in the middle. Same
// visual language as the shell's own network-speed-test dials.
Item {
  id: root

  property real value: 0
  property string valueText: ""
  property string label: ""
  property color gaugeColor: Color.accent
  readonly property var scaleStops: [4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864, 268435456]

  readonly property real diameter: Style.space(108)
  readonly property real dialStart: 135
  readonly property real dialSweep: 270
  readonly property real arcWidth: Style.space(6)
  readonly property real arcRadius: diameter / 2 - arcWidth

  property real fullScale: scaleStops[0]
  property real shown: 0
  readonly property real fraction: fullScale > 0 ? Math.max(0, Math.min(1, shown / fullScale)) : 0

  function expandScale(v) {
    for (var i = 0; i < scaleStops.length; i++) {
      if (v <= scaleStops[i] * 0.92) {
        if (scaleStops[i] > fullScale) fullScale = scaleStops[i]
        return
      }
    }
    fullScale = scaleStops[scaleStops.length - 1]
  }

  onValueChanged: {
    expandScale(value)
    shown = value
  }

  Behavior on shown {
    NumberAnimation { duration: 450; easing.type: Easing.OutCubic }
  }
  Behavior on fullScale {
    NumberAnimation { duration: 450; easing.type: Easing.OutCubic }
  }

  width: diameter
  height: diameter + Style.space(18)

  Shape {
    id: dialShape
    width: root.diameter
    height: root.diameter
    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.14)
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: root.diameter / 2
        centerY: root.diameter / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep
      }
    }

    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: root.fraction > 0.004 ? root.gaugeColor : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: root.diameter / 2
        centerY: root.diameter / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep * root.fraction
      }
    }
  }

  Text {
    anchors.centerIn: dialShape
    anchors.verticalCenterOffset: Style.space(6)
    textFormat: Text.PlainText
    text: root.valueText
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  Text {
    anchors.top: dialShape.bottom
    anchors.topMargin: Style.space(2)
    anchors.horizontalCenter: parent.horizontalCenter
    textFormat: Text.PlainText
    text: root.label
    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.68)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1
  }
}

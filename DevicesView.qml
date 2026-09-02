import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: root
  required property var panel
  width: parent.width
  spacing: Style.space(8)

  PanelSectionHeader {
    text: "Devices On Your Network"
    foreground: Color.popups.text
    fontFamily: Style.font.family
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: "From your local ARP/neighbor table -- other devices your machine has recently talked to on this network."
    color: panel.mutedText
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    visible: panel.devices.length === 0
    textFormat: Text.PlainText
    text: "No neighboring devices discovered yet."
    color: panel.mutedText
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: panel.devices

    Row {
      required property var modelData
      width: root.width
      height: Style.space(26)
      spacing: Style.space(10)

      Rectangle {
        id: ipHighlight
        width: Style.space(130)
        height: Style.space(20)
        radius: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        color: ipMouse.containsMouse ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14) : "transparent"

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: modelData.ip
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          id: ipMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: panel.copyToClipboard(modelData.ip)
        }

        PanelToolTip {
          visible: ipMouse.containsMouse
          text: "Copy to clipboard"
          fontFamily: Style.font.family
        }
      }
      Text {
        width: Style.space(150)
        textFormat: Text.PlainText
        text: modelData.mac !== "" ? modelData.mac : "—"
        color: panel.mutedText
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: modelData.state
        color: (modelData.state === "REACHABLE" || modelData.state === "PERMANENT") ? panel.downColor : panel.mutedText
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}

import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: root
  required property var panel
  width: parent.width
  spacing: Style.space(8)

  Item {
    width: parent.width
    height: Math.max(headerCol.implicitHeight, collapseAllLink.implicitHeight)

    Column {
      id: headerCol
      anchors.left: parent.left
      anchors.right: collapseAllLink.left
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      PanelSectionHeader {
        text: "Active Connections"
        foreground: Color.popups.text
        fontFamily: Style.font.family
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "Nested by process, with a country flag for each remote IP. Click an IP for a whois lookup, or use the copy icon to copy it."
        color: panel.mutedText
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      id: collapseAllLink
      visible: panel.whoisRowKey !== ""
      anchors.right: parent.right
      anchors.top: parent.top
      textFormat: Text.PlainText
      text: "Collapse"
      color: Color.accent
      font.underline: true
      font.family: Style.font.family
      font.pixelSize: Style.font.caption

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: panel.collapseWhois()
      }
    }
  }

  Text {
    visible: panel.connections.length === 0
    textFormat: Text.PlainText
    text: "No active connections found."
    color: panel.mutedText
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: panel.groupedConnections

    Column {
      id: groupItem
      required property var modelData
      width: root.width
      spacing: Style.space(4)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: groupItem.modelData.process !== "" ? groupItem.modelData.process : "Unknown"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          text: "(" + groupItem.modelData.items.length + ")"
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Column {
        id: itemsCol
        x: Style.space(14)
        width: parent.width - Style.space(14)
        spacing: Style.space(4)

        Repeater {
          model: groupItem.modelData.items

          Column {
            id: rowItem
            required property var modelData
            width: itemsCol.width
            spacing: Style.space(4)

            readonly property string rowKey: panel.connectionRowKey(rowItem.modelData)
            readonly property bool expanded: panel.whoisRowKey === rowItem.rowKey

            Row {
              width: parent.width
              height: Style.space(22)
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: panel.flagFor(rowItem.modelData.remoteIp)
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              Rectangle {
                id: ipHighlight
                width: Style.space(130)
                height: Style.space(20)
                radius: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                color: ipMouse.containsMouse ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14) : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: rowItem.modelData.remoteIp
                  color: rowItem.expanded ? Color.accent : Color.popups.text
                  font.underline: true
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: ipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: panel.toggleWhois(rowItem.rowKey, rowItem.modelData.remoteIp)
                }

                PanelToolTip {
                  visible: ipMouse.containsMouse
                  text: "Click for whois lookup"
                  fontFamily: Style.font.family
                }
              }
              Text {
                id: copyIpGlyph
                textFormat: Text.PlainText
                text: "📋"
                color: copyIpMouse.containsMouse ? Color.accent : panel.mutedText
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  id: copyIpMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: panel.copyToClipboard(rowItem.modelData.remoteIp)
                }

                PanelToolTip {
                  visible: copyIpMouse.containsMouse
                  text: "Copy to clipboard"
                  fontFamily: Style.font.family
                }
              }
              Text {
                width: Style.space(50)
                textFormat: Text.PlainText
                text: rowItem.modelData.remotePort
                color: panel.mutedText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: rowItem.modelData.protocol.toUpperCase()
                color: panel.mutedText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            BorderSurface {
              visible: rowItem.expanded
              width: parent.width
              height: Math.min(Style.space(180), whoisBody.implicitHeight + Style.space(20))
              radius: Style.cornerRadius
              color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.05)
              borderSpec: Border.flat(Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.12), 1)

              Flickable {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                anchors.rightMargin: Style.space(50)
                contentWidth: width
                contentHeight: whoisBody.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Text {
                  id: whoisBody
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.WrapAnywhere
                  text: panel.whoisLoading ? "Looking up whois…" : (panel.whoisText || "No data.")
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(4)
                spacing: Style.space(2)

                PanelActionButton {
                  iconText: "📋"
                  tooltipText: "Copy whois info"
                  foreground: Color.popups.text
                  size: Style.space(20)
                  fontSize: Style.font.caption
                  onClicked: panel.copyToClipboard(panel.whoisText)
                }
                PanelActionButton {
                  iconText: "×"
                  tooltipText: "Close"
                  foreground: Color.popups.text
                  hoverColor: Color.urgent
                  size: Style.space(20)
                  fontSize: Style.font.body
                  onClicked: panel.collapseWhois()
                }
              }
            }
          }
        }
      }
    }
  }

  Text {
    visible: panel.connectionsTruncated
    textFormat: Text.PlainText
    text: "Showing the first " + panel.connections.length + " connections."
    color: panel.mutedText
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}

import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root
  required property var panel
  width: parent.width
  spacing: Style.space(14)

  readonly property real colWidth: (root.width - Style.space(36)) / 4

  PanelSectionHeader {
    text: "Usage"
    foreground: Color.popups.text
    fontFamily: Style.font.family
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: "Byte totals per TCP connection since it opened, straight from the kernel's own counters, grouped four ways. UDP traffic (DNS, mDNS, SSDP, ...) shows in Connections but isn't counted here -- those sockets carry no byte counters to sum."
    color: panel.mutedText
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Grid {
    width: parent.width
    columns: 4
    columnSpacing: Style.space(12)

    Repeater {
      model: [
        { title: "Apps", data: panel.usageByApp, tint: panel.downColor },
        { title: "Hosts", data: panel.usageByHost, tint: panel.upColor },
        { title: "Traffic Type", data: panel.usageByType, tint: panel.downColor },
        { title: "Countries", data: panel.usageByCountry, tint: panel.upColor, flags: true }
      ]

      Column {
        id: col
        required property var modelData
        width: root.colWidth
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: col.modelData.title
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          visible: col.modelData.data.length === 0
          textFormat: Text.PlainText
          text: "No data yet"
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: col.modelData.data.slice(0, 6)

          Column {
            id: entryItem
            required property var modelData
            width: col.width
            spacing: Style.space(2)

            readonly property real topBytes: col.modelData.data.length > 0 ? col.modelData.data[0].bytes : 1
            readonly property var countryParts: col.modelData.flags ? entryItem.modelData.label.split("|") : []
            readonly property string displayLabel: countryParts.length === 2
              ? (Model.countryFlagEmoji(countryParts[0]) + " " + countryParts[1]).trim()
              : entryItem.modelData.label

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: entryItem.displayLabel
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              textFormat: Text.PlainText
              text: Model.formatBytes(entryItem.modelData.bytes)
              color: panel.mutedText
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Rectangle {
              width: Math.max(2, col.width * (entryItem.topBytes > 0 ? entryItem.modelData.bytes / entryItem.topBytes : 0))
              height: Style.space(3)
              radius: Style.space(2)
              color: col.modelData.tint
            }
          }
        }
      }
    }
  }

  PanelSeparator { foreground: Color.popups.text }

  Item {
    width: parent.width
    height: Math.max(statsRow.implicitHeight, wanLanCol.implicitHeight)

    Row {
      id: statsRow
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(18)

      Column {
        spacing: Style.space(1)
        Text {
          textFormat: Text.PlainText
          text: panel.sessionDownText
          color: panel.downColor
          font.bold: true
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          text: "↓ " + panel.downRateText
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // Reuses the new-app alert count from the Traffic-tab-adjacent
      // background poller as a small badge -- a real, non-decorative number
      // rather than the alert bell being cloned as inert decoration.
      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Style.space(38)
          height: Style.space(38)
          radius: width / 2
          color: "transparent"
          border.width: 2
          border.color: Color.accent

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: panel.newAppAlertCount
            color: Color.popups.text
            font.bold: true
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: "new apps"
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Column {
        spacing: Style.space(1)
        Text {
          textFormat: Text.PlainText
          text: panel.sessionUpText
          color: panel.upColor
          font.bold: true
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
        Text {
          textFormat: Text.PlainText
          text: "↑ " + panel.upRateText
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    Column {
      id: wanLanCol
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(220)
      spacing: Style.space(6)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: Style.space(32)
          textFormat: Text.PlainText
          text: "WAN"
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
          width: Style.space(112)
          height: Style.space(6)
          radius: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)

          Rectangle {
            readonly property real totalBytes: panel.usageWanBytes + panel.usageLanBytes
            width: parent.width * (totalBytes > 0 ? panel.usageWanBytes / totalBytes : 0)
            height: parent.height
            radius: parent.radius
            color: panel.downColor
          }
        }
        Text {
          width: Style.space(60)
          textFormat: Text.PlainText
          text: panel.usageWanText
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          width: Style.space(32)
          textFormat: Text.PlainText
          text: "LAN"
          color: panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
          width: Style.space(112)
          height: Style.space(6)
          radius: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter
          color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.10)

          Rectangle {
            readonly property real totalBytes: panel.usageWanBytes + panel.usageLanBytes
            width: parent.width * (totalBytes > 0 ? panel.usageLanBytes / totalBytes : 0)
            height: parent.height
            radius: parent.radius
            color: panel.upColor
          }
        }
        Text {
          width: Style.space(60)
          textFormat: Text.PlainText
          text: panel.usageLanText
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}

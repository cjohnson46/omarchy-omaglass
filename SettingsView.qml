import QtQuick
import qs.Commons
import qs.Ui
import "Themes.js" as Themes

Column {
  id: root
  required property var panel
  width: parent.width
  spacing: Style.space(14)

  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: "Theme"
      foreground: Color.popups.text
      fontFamily: Style.font.family
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Pick a color pair for the graph and gauges, or stay on your live Omarchy theme."
      color: panel.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Flow {
    width: parent.width
    spacing: Style.space(10)

    Repeater {
      model: Themes.THEMES

      Column {
        id: themeItem
        required property var modelData
        spacing: Style.space(4)

        readonly property bool selected: panel.themeId === modelData.id
        readonly property color swatchDown: modelData.dynamic ? Color.accent : modelData.download
        readonly property color swatchUp: modelData.dynamic ? Color.urgent : modelData.upload

        Rectangle {
          width: Style.space(54)
          height: Style.space(30)
          radius: Style.cornerRadius > 0 ? Style.space(6) : 0
          border.width: themeItem.selected ? 2 : 1
          border.color: themeItem.selected
            ? Color.accent
            : Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.18)

          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: themeItem.swatchDown }
            GradientStop { position: 1.0; color: themeItem.swatchUp }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: panel.setTheme(themeItem.modelData.id)
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: themeItem.modelData.name
          color: themeItem.selected ? Color.popups.text : panel.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  PanelSeparator { foreground: Color.popups.text }

  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: "Bar Icon"
      foreground: Color.popups.text
      fontFamily: Style.font.family
    }

    Toggle {
      width: parent.width
      label: "Match other bar icons"
      description: "Use the same neutral color as the rest of the bar for the small graph, instead of the traffic theme colors above. Only affects the bar icon -- the popup graph always uses the theme colors."
      checked: panel.barMonotone
      foreground: Color.popups.text
      accent: Color.accent
      onClicked: panel.setBarMonotone(!panel.barMonotone)
    }
  }

  PanelSeparator { foreground: Color.popups.text }

  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: "Notifications"
      foreground: Color.popups.text
      fontFamily: Style.font.family
    }

    Toggle {
      width: parent.width
      label: "Notify on new apps"
      description: "Send a desktop notification the first time a process starts talking to the network each session. Off by default -- the count still shows in the Usage tab either way."
      checked: panel.newAppNotifications
      foreground: Color.popups.text
      accent: Color.accent
      onClicked: panel.setNewAppNotifications(!panel.newAppNotifications)
    }
  }

  PanelSeparator { foreground: Color.popups.text }

  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: "Default Graph Window"
      foreground: Color.popups.text
      fontFamily: Style.font.family
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Which window the Traffic tab's graph starts on when you open the popup. Picking a different window there for that session doesn't change this."
      color: panel.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Row {
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
          readonly property bool active: panel.defaultHistoryWindowSeconds === modelData.key
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
            onClicked: panel.setDefaultHistoryWindow(modelData.key)
          }
        }
      }
    }
  }

  PanelSeparator { foreground: Color.popups.text }

  Column {
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      text: "About This Data"
      foreground: Color.popups.text
      fontFamily: Style.font.family
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Connections and usage totals come from your own processes' sockets (via ss, including the kernel's own byte counters for Usage), and devices come from your local network's neighbor table (via ip neigh) -- all of that stays on this machine. Country flags and Usage's Countries column are looked up over HTTPS from ipwho.is, a free public GeoIP service, one address at a time: only public IPs you're already connected to are ever looked up, and private/local addresses are never sent. Hostnames in Usage come from a reverse-DNS lookup (getent) against your configured DNS resolver."
      color: panel.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Clicking an IP in Connections runs a whois lookup for that address, spoken directly to IANA's registry servers -- no external whois tool required. New-app tracking watches for process names you haven't seen talk to the network yet this session; the desktop notification for it is off by default (see Notifications above) -- nothing is ever blocked, it's just a heads-up when you opt in."
      color: panel.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "The LAN lines on the Traffic graph total bytes_sent/bytes_received (from ss's TCP info) across your currently-open sockets to private-network addresses, sampled every second and diffed like the main rate. Two honest limits: UDP isn't counted (no byte counters for it), and a connection that closes between samples takes its bytes with it -- this tracks currently-open LAN sockets, not a true running LAN total."
      color: panel.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "To keep this plugin's own footprint lean, its background sampling runs at full speed only while this popup is open; closed, it polls at a fourth the rate. This is a read-only monitor -- no blocking or firewall controls."
      color: panel.mutedText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.Compositor
import qs.Services.UI
import qs.Widgets

Item {
  id: root
  property var pluginApi: null

  property bool panelAnchorTop: true
  property bool panelAnchorRight: true
  property bool allowAttach: false

  property real contentPreferredWidth: 300
  property real contentPreferredHeight: panelColumn.implicitHeight + Style.marginL * 2

  readonly property var mainInstance: pluginApi?.mainInstance ?? null
  readonly property bool discordConnected: mainInstance?.discordConnected ?? false
  readonly property bool discordNeedsSetup: mainInstance?.discordNeedsSetup ?? false
  readonly property bool discordNeedsAuth: mainInstance?.discordNeedsAuth ?? false
  readonly property string voiceStatusText: mainInstance?.voiceStatusText ?? "Discord not connected"
  readonly property var voiceParticipants: mainInstance?.voiceParticipants ?? []

  readonly property string currentGameTitle: {
    var title = CompositorService.getFocusedWindowTitle();
    if (!title || /^(Steam|Friends List|Desktop)$/.test(title.trim())) return "";
    return title;
  }

  ColumnLayout {
    id: panelColumn
    anchors {
      left: parent.left
      right: parent.right
      top: parent.top
      margins: Style.marginL
    }
    spacing: Style.marginS

    // Game title
    NBox {
      Layout.fillWidth: true
      visible: currentGameTitle !== ""
      implicitHeight: gameRow.implicitHeight + Style.margin2S

      RowLayout {
        id: gameRow
        anchors {
          left: parent.left
          right: parent.right
          verticalCenter: parent.verticalCenter
          margins: Style.marginS
        }
        spacing: Style.marginXS

        NIcon {
          icon: "device-gamepad-2"
          pointSize: Style.fontSizeL
          color: Color.mPrimary
          applyUiScale: false
        }

        NText {
          Layout.fillWidth: true
          text: currentGameTitle
          pointSize: Style.fontSizeM
          font.weight: Style.fontWeightSemiBold
          color: Color.mOnSurface
          elide: Text.ElideRight
        }
      }
    }

    // Discord voice
    NBox {
      Layout.fillWidth: true
      implicitHeight: discordColumn.implicitHeight + Style.margin2S

      ColumnLayout {
        id: discordColumn
        anchors {
          left: parent.left
          right: parent.right
          top: parent.top
          margins: Style.marginS
        }
        spacing: Style.marginXS

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.marginXS

          NIcon {
            icon: "brand-discord"
            pointSize: Style.fontSizeL
            color: discordConnected ? Color.mPrimary : Color.mOnSurfaceVariant
            applyUiScale: false
            opacity: discordNeedsAuth ? 0.6 : 1.0
            Behavior on opacity { NumberAnimation { duration: 200 } }
          }

          NText {
            Layout.fillWidth: true
            text: voiceStatusText
            pointSize: Style.fontSizeS
            font.weight: Style.fontWeightSemiBold
            color: discordConnected ? Color.mOnSurface : Color.mOnSurfaceVariant
            elide: Text.ElideRight
          }
        }

        NText {
          visible: discordNeedsSetup
          Layout.fillWidth: true
          text: "1. discord.com/developers/applications\n2. Create app -> enable RPC\n3. Add client_id + client_secret to\n   omni-overlay/config.json"
          pointSize: Style.fontSizeXS
          color: Color.mOnSurfaceVariant
          wrapMode: Text.WordWrap
        }

        NText {
          visible: discordNeedsAuth && !discordNeedsSetup
          Layout.fillWidth: true
          text: "Approve in Discord's authorization dialog"
          pointSize: Style.fontSizeXS
          color: Color.mOnSurfaceVariant
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: voiceParticipants
          delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.marginXS

            Rectangle {
              width: 7
              height: 7
              radius: 4
              color: modelData.speaking ? Color.mPrimary : Color.mOnSurfaceVariant
              opacity: modelData.speaking ? 1.0 : 0.4
              Behavior on color { ColorAnimation { duration: 80 } }
              Behavior on opacity { NumberAnimation { duration: 80 } }
            }

            NText {
              Layout.fillWidth: true
              text: modelData.nick
              pointSize: Style.fontSizeS
              color: modelData.speaking ? Color.mPrimary : Color.mOnSurface
              elide: Text.ElideRight
              Behavior on color { ColorAnimation { duration: 80 } }
            }

            NIcon {
              visible: modelData.mute || modelData.deaf
              icon: modelData.deaf ? "headphones-off" : "microphone-off"
              pointSize: Style.fontSizeS
              color: Color.mOnSurfaceVariant
              applyUiScale: false
            }
          }
        }
      }
    }
  }
}

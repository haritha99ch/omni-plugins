import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
  id: root
  property var  pluginApi: null
  property bool panelsVisible: true
  property bool active: true

  // State
  property bool steamReady: false
  property var  steamFriends: []
  property var  steamMessages: ({})

  // Bridge (mirrors ObsWidget pattern)
  function _sync() {
    var want = active && panelsVisible && !!pluginApi;
    if (want && !steamBridge.running)       steamBridge.running = true;
    else if (!want && steamBridge.running) { steamBridge.running = false; root.steamReady = false; }
  }
  onPluginApiChanged: _sync()
  onPanelsVisibleChanged: _sync()
  onActiveChanged: _sync()

  Process {
    id: steamBridge; running: false; stdinEnabled: true
    command: [root.pluginApi ? root.pluginApi.pluginDir + "/scripts/steam-friends.py" : "true"]
    stdout: SplitParser {
      onRead: function(line) {
        if (!line.trim()) return;
        try {
          var msg = JSON.parse(line); var d = msg.data || {};
          switch (msg.type) {
            case "steam_ready": root.steamReady = true; break;
            case "steam_error": root.steamReady = false; Logger.w("Steam", d.message); break;
            case "steam_friends": root.steamFriends = d.friends || []; break;
            case "steam_persona": {
              var idx = root.steamFriends.findIndex(function(f){ return f.steamid===d.steamid; });
              var list = root.steamFriends.slice();
              if (idx >= 0) list[idx] = d; else list.push(d);
              root.steamFriends = list;
              break;
            }
            case "steam_message": {
              var sid = d.steamid || "";
              var hist = (root.steamMessages[sid] || []).slice();
              hist.push({ name: d.name, text: d.text, outgoing: d.outgoing, ts: d.ts });
              root.steamMessages = Object.assign({}, root.steamMessages, { [sid]: hist });
              if (!d.outgoing) ToastService.showNotice(d.name, d.text, "message");
              break;
            }
          }
        } catch(e) {}
      }
    }
    onExited: function(code) { root.steamReady = false; if (code !== 0) steamRetry.restart(); }
  }
  Timer { id: steamRetry; interval: 8000; repeat: false; onTriggered: _sync() }

  function steamSend(sid, text)  { if (steamBridge.running) steamBridge.write(JSON.stringify({ action: "send",   steamid: sid, text: text }) + "\n"); }
  function steamInvite(sid)      { if (steamBridge.running) steamBridge.write(JSON.stringify({ action: "invite", steamid: sid }) + "\n"); }
  function steamRefresh()        { if (steamBridge.running) steamBridge.write(JSON.stringify({ action: "refresh" }) + "\n"); }

  property string selectedSteamId: ""
  readonly property var selectedFriend: steamFriends.find(function(f){ return f.steamid===selectedSteamId; }) ?? null

  implicitWidth: 280
  implicitHeight: Math.min(sRect.implicitHeight, parent?.height > 0 ? parent.height - y - 10 : 800)
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    id: sRect
    width: 280; implicitHeight: sCol.implicitHeight + Style.marginL * 2; height: root.implicitHeight
    color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusL; clip: true

    ColumnLayout {
      id: sCol
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginL }
      spacing: Style.marginS

      // Header
      RowLayout {
        Layout.fillWidth: true; spacing: Style.marginS
        NIcon { icon: "brand-steam"; pointSize: Style.fontSizeXL; color: Color.mPrimary; applyUiScale: false }
        NText { Layout.fillWidth: true; text: "Steam"; pointSize: Style.fontSizeM; font.weight: Style.fontWeightBold; color: Color.mOnSurface }
        Rectangle { width: 8; height: 8; radius: 4; color: root.steamReady?Color.mPrimary:Color.mOnSurfaceVariant; Behavior on color{ColorAnimation{duration:300}} }
        NIconButton { icon: "refresh"; baseSize: Style.baseWidgetSize*0.7; visible: root.steamReady; onClicked: root.mi?.steamRefresh() }
      }

      NText { visible: !root.steamReady; Layout.fillWidth: true; text: "Steam not connected\nMake sure Steam is running"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant; wrapMode: Text.WordWrap }

      // Chat view
      ColumnLayout {
        visible: root.steamReady && root.selectedSteamId !== ""; Layout.fillWidth: true; spacing: Style.marginXS

        RowLayout {
          Layout.fillWidth: true; spacing: Style.marginXS
          NIconButton { icon: "arrow-left"; baseSize: Style.baseWidgetSize*0.7; onClicked: root.selectedSteamId="" }
          Item {
            readonly property int sz: Math.round(22*Style.uiScaleRatio); width: sz; height: sz
            Rectangle { anchors.fill: parent; radius: width/2; color: Color.mSurfaceVariant; clip: true
              Image { id: chAvImg; anchors.fill: parent; source: root.selectedFriend?.avatar_b64?"data:image/png;base64,"+root.selectedFriend.avatar_b64:""; fillMode: Image.PreserveAspectCrop; asynchronous: true; visible: status===Image.Ready }
              NText { visible: !chAvImg.visible; anchors.centerIn: parent; text: (root.selectedFriend?.name||"?")[0].toUpperCase(); pointSize: Style.fontSizeXXS; color: Color.mOnSurfaceVariant }
            }
          }
          NText { Layout.fillWidth: true; text: root.selectedFriend?.name??""; pointSize: Style.fontSizeS; font.weight: Style.fontWeightSemiBold; color: Color.mOnSurface; elide: Text.ElideRight }
          NIconButton { icon: "device-gamepad-2"; tooltipText: "Invite to game"; baseSize: Style.baseWidgetSize*0.7; visible: (root.selectedFriend?.gameid??0)>0; colorFg: Color.mPrimary; onClicked: root.mi?.steamInvite(root.selectedSteamId) }
        }

        Flickable {
          id: chatFlick; Layout.fillWidth: true
          implicitHeight: Math.min(msgCol.implicitHeight, Math.round(160*Style.uiScaleRatio)); contentHeight: msgCol.implicitHeight; clip: true
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          onContentHeightChanged: contentY=Math.max(0,contentHeight-height)
          Column { id: msgCol; width: chatFlick.width; spacing: 3
            Repeater {
              model: root.steamMessages[root.selectedSteamId] ?? []
              delegate: Item {
                required property var modelData; width: msgCol.width; implicitHeight: bubble.implicitHeight+2
                Rectangle {
                  id: bubble
                  anchors { right: modelData.outgoing?parent.right:undefined; left: modelData.outgoing?undefined:parent.left }
                  width: Math.min(bTxt.implicitWidth+Style.marginS*2, parent.width*0.82)
                  implicitHeight: bTxt.implicitHeight+Style.marginXS*2; radius: Style.radiusS
                  color: modelData.outgoing?Qt.alpha(Color.mPrimary,0.25):Color.mSurfaceVariant
                  NText { id: bTxt; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginXS } text: modelData.text; pointSize: Style.fontSizeXS; wrapMode: Text.WordWrap; color: Color.mOnSurface }
                }
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true; spacing: Style.marginXS
          TextField { id: chatField; Layout.fillWidth: true; placeholderText: "Message..."; placeholderTextColor: Color.mSecondary; font.pointSize: Style.fontSizeXS; color: Color.mOnSurface; background: Rectangle { color: Color.mSurfaceVariant; radius: Style.radiusS }
            onAccepted: { if (text.trim()!=="") { root.mi?.steamSend(root.selectedSteamId,text.trim()); text=""; } }
          }
          NIconButton { icon: "send"; baseSize: Style.baseWidgetSize*0.8; enabled: chatField.text.trim()!==""; onClicked: { if(chatField.text.trim()!==""){root.mi?.steamSend(root.selectedSteamId,chatField.text.trim());chatField.text="";} } }
        }
      }

      // Friends list
      ColumnLayout {
        visible: root.steamReady && root.selectedSteamId===""; Layout.fillWidth: true; spacing: 2
        NText { visible: root.steamFriends.length===0; Layout.fillWidth: true; text: "No friends online"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant; horizontalAlignment: Text.AlignHCenter }

        Flickable {
          Layout.fillWidth: true
          implicitHeight: Math.min(fCol.implicitHeight, Math.round(280*Style.uiScaleRatio)); contentHeight: fCol.implicitHeight; clip: true
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          Column { id: fCol; width: parent.width; spacing: 2
            Repeater {
              model: root.steamFriends
              delegate: Rectangle {
                required property var modelData
                width: fCol.width; implicitHeight: fRow.implicitHeight+Style.marginXXS*2; height: implicitHeight; radius: Style.radiusS
                color: fHov.containsMouse?Qt.alpha(Color.mPrimary,0.08):"transparent"; Behavior on color{ColorAnimation{duration:80}}

                RowLayout { id: fRow; anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.marginXS; rightMargin: Style.marginXS } spacing: Style.marginS
                  Rectangle { width: 8; height: 8; radius: 4
                    color: { var s=modelData.stateid; if(s===0)return Qt.alpha(Color.mOnSurfaceVariant,0.35); if(s===1)return Color.mPrimary; if(s===2)return Color.mError; return Color.mOnSurfaceVariant; }
                  }
                  ColumnLayout { Layout.fillWidth: true; spacing: 0
                    NText { Layout.fillWidth: true; text: modelData.name; pointSize: Style.fontSizeS; color: modelData.stateid===0?Color.mOnSurfaceVariant:Color.mOnSurface; elide: Text.ElideRight }
                    NText { visible: (modelData.richpresence||"")!==""; text: modelData.richpresence||""; pointSize: Style.fontSizeXXS; color: Color.mPrimary; elide: Text.ElideRight; Layout.fillWidth: true }
                  }
                  Rectangle { visible: (root.steamMessages[modelData.steamid]??[]).some(function(m){return !m.outgoing;}); width: 7; height: 7; radius: 4; color: Color.mPrimary }
                }
                MouseArea { id: fHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selectedSteamId=modelData.steamid }
              }
            }
          }
        }
      }
    }
  }
}

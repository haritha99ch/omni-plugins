import QtQuick
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

  // OBS state
  property bool obsConnected: false
  property bool obsRecording: false
  property bool obsStreaming: false
  property bool obsReplayActive: false
  property int  obsRecordMs: 0
  property int  obsStreamMs: 0

  function obsCmd(action) {
    if (obsBridge.running) obsBridge.write(JSON.stringify({ action: action }) + "\n");
  }

  function formatObsTime(ms) {
    var s   = Math.floor(ms / 1000);
    var h   = Math.floor(s / 3600);
    var m   = Math.floor((s % 3600) / 60);
    var sec = s % 60;
    var pad = function(n) { return n < 10 ? "0" + n : "" + n; };
    return (h > 0 ? h + ":" : "") + pad(m) + ":" + pad(sec);
  }

  // Bridge process
  Process {
    id: obsBridge
    running: false
    stdinEnabled: true
    command: [root.pluginApi ? root.pluginApi.pluginDir + "/widgets/obs/scripts/obs-ws.py" : "true"]
    stdout: SplitParser {
      onRead: function(line) {
        if (!line.trim()) return;
        try {
          var msg = JSON.parse(line); var d = msg.data || {};
          switch (msg.type) {
            case "obs_connected": root.obsConnected = true; break;
            case "obs_disconnected": root.obsConnected = false; break;
            case "obs_status":
              root.obsRecording    = d.recording     ?? false;
              root.obsStreaming     = d.streaming     ?? false;
              root.obsReplayActive = d.replay_buffer ?? false;
              root.obsRecordMs     = d.record_ms     ?? 0;
              root.obsStreamMs     = d.stream_ms     ?? 0;
              break;
          }
        } catch(e) {}
      }
    }
    onExited: function(code) {
      root.obsConnected = false;
      if (code !== 0) obsRetry.restart();
    }
  }

  Timer { id: obsRetry; interval: 5000; repeat: false; onTriggered: _sync() }

  function _sync() {
    var want = !!(pluginApi && panelsVisible && active);
    if (want && !obsBridge.running)       obsBridge.running = true;
    else if (!want && obsBridge.running) { obsBridge.running = false; root.obsConnected = false; }
  }

  onPluginApiChanged: _sync()
  onPanelsVisibleChanged: _sync()
  onActiveChanged: _sync()

  // Sizing
  implicitWidth: 280
  implicitHeight: obsRect.height
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    id: obsRect
    width: 280; height: obsCol.implicitHeight + Style.marginL * 2
    color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusL; clip: true

    ColumnLayout {
      id: obsCol
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginL }
      spacing: Style.marginS

      RowLayout {
        Layout.fillWidth: true; spacing: Style.marginS
        NIcon { icon: "brand-youtube"; pointSize: Style.fontSizeXL; color: Color.mPrimary; applyUiScale: false }
        NText { Layout.fillWidth: true; text: "OBS Studio"; pointSize: Style.fontSizeM; font.weight: Style.fontWeightBold; color: Color.mOnSurface }
        Rectangle { width: 8; height: 8; radius: 4; color: root.obsConnected ? Color.mPrimary : Color.mOnSurfaceVariant; Behavior on color { ColorAnimation { duration: 300 } } }
      }

      NText {
        visible: !root.obsConnected; Layout.fillWidth: true
        text: "OBS not connected\nEnable WebSocket in OBS ->\nTools -> obs-websocket Settings"
        pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant; wrapMode: Text.WordWrap
      }

      ColumnLayout {
        visible: root.obsConnected; Layout.fillWidth: true; spacing: Style.marginS

        NBox {
          Layout.fillWidth: true; implicitHeight: recRow.implicitHeight + Style.margin2S
          color: root.obsRecording ? Qt.alpha(Color.mPrimary, 0.12) : Color.mSurfaceVariant
          RowLayout { id: recRow; anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: Style.marginS } spacing: Style.marginS
            Rectangle { width: 10; height: 10; radius: 5; color: root.obsRecording?Color.mPrimary:Color.mOnSurfaceVariant; opacity: root.obsRecording?1.0:0.4; Behavior on color{ColorAnimation{duration:150}} Behavior on opacity{NumberAnimation{duration:150}} }
            NText { Layout.fillWidth: true; text: root.obsRecording?("REC  "+root.formatObsTime(root.obsRecordMs)):"Not Recording"; pointSize: Style.fontSizeS; font.family: root.obsRecording?Settings.data.ui.fontFixed:""; color: root.obsRecording?Color.mPrimary:Color.mOnSurfaceVariant; font.weight: root.obsRecording?Style.fontWeightSemiBold:Font.Normal }
            NIconButton { icon: root.obsRecording?"player-stop-filled":"player-record"; colorFg: root.obsRecording?Color.mPrimary:Color.mOnSurface; colorBg: root.obsRecording?Qt.alpha(Color.mPrimary,0.15):Style.capsuleColor; baseSize: Style.baseWidgetSize*0.8; onClicked: root.obsCmd("toggle_record") }
          }
        }

        NBox {
          Layout.fillWidth: true; implicitHeight: stmRow.implicitHeight + Style.margin2S
          color: root.obsStreaming ? Qt.alpha(Color.mPrimary, 0.12) : Color.mSurfaceVariant
          RowLayout { id: stmRow; anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: Style.marginS } spacing: Style.marginS
            Rectangle { width: 10; height: 10; radius: 5; color: root.obsStreaming?Color.mPrimary:Color.mOnSurfaceVariant; opacity: root.obsStreaming?1.0:0.4; Behavior on color{ColorAnimation{duration:150}} Behavior on opacity{NumberAnimation{duration:150}} }
            NText { Layout.fillWidth: true; text: root.obsStreaming?("LIVE  "+root.formatObsTime(root.obsStreamMs)):"Not Streaming"; pointSize: Style.fontSizeS; font.family: root.obsStreaming?Settings.data.ui.fontFixed:""; color: root.obsStreaming?Color.mPrimary:Color.mOnSurfaceVariant; font.weight: root.obsStreaming?Style.fontWeightSemiBold:Font.Normal }
            NIconButton { icon: root.obsStreaming?"player-stop-filled":"live-view"; colorFg: root.obsStreaming?Color.mPrimary:Color.mOnSurface; colorBg: root.obsStreaming?Qt.alpha(Color.mPrimary,0.15):Style.capsuleColor; baseSize: Style.baseWidgetSize*0.8; onClicked: root.obsCmd("toggle_stream") }
          }
        }

        RowLayout {
          Layout.fillWidth: true; spacing: Style.marginS
          NIconButton { icon: root.obsReplayActive?"player-stop-filled":"clock-play"; tooltipText: root.obsReplayActive?"Stop Replay Buffer":"Start Replay Buffer"; colorFg: root.obsReplayActive?Color.mPrimary:Color.mOnSurface; colorBg: root.obsReplayActive?Qt.alpha(Color.mPrimary,0.15):Style.capsuleColor; onClicked: root.obsCmd("toggle_replay") }
          NText { Layout.fillWidth: true; text: root.obsReplayActive?"Replay buffer active":"Replay buffer off"; pointSize: Style.fontSizeXS; color: root.obsReplayActive?Color.mPrimary:Color.mOnSurfaceVariant }
          NIconButton { visible: root.obsReplayActive; icon: "device-floppy"; tooltipText: "Save Replay"; onClicked: root.obsCmd("save_replay") }
        }
      }
    }
  }
}

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

  // Discord bridge
  property bool discordConnected: false
  property bool discordNeedsSetup: false
  property bool discordNeedsAuth: false
  property string discordSetupMessage: ""
  property string discordUsername: ""
  property string discordUserId: ""
  property string voiceChannelName: ""
  property var voiceParticipants: []
  property bool discordSelfMuted: false
  property bool discordSelfDeafened: false
  readonly property bool discordInVoice: voiceChannelName !== ""
  property bool voiceHudPinned: false
  readonly property bool persistWhenHidden: voiceHudPinned && discordInVoice

  property var guilds: []
  property var guildChannels: ({})
  property bool guildsLoading: false
  property var channelsLoading: ({})

  readonly property string voiceStatusText: {
    if (discordNeedsSetup) return "Discord  -  setup required";
    if (discordNeedsAuth)  return "Discord  -  authorizing...";
    if (!discordConnected) return "Discord not connected";
    return voiceChannelName !== "" ? voiceChannelName : "Connected  -  no voice channel";
  }

  property bool settingsOpen: false

  onPluginApiChanged: { if (pluginApi) _startBridge(); }

  // Writes discord credentials to ~/.config/omni-overlay/discord/config.json
  Process {
    id: configSaver
    running: false
    stdinEnabled: true
    command: ["python3", "-c",
      "import json,os,sys; d=json.loads(sys.stdin.readline()); p=os.path.expanduser('~/.config/omni-overlay/discord/config.json'); os.makedirs(os.path.dirname(p),exist_ok=True); open(p,'w').write(json.dumps(d,indent=2))"]
    onExited: function(code) {
      if (code === 0) {
        root.settingsOpen = false;
        if (bridge.running) bridge.running = false;
        Qt.callLater(function(){ root._startBridge(); });
      }
    }
  }

  function saveCredentials(clientId, secret) {
    if (!clientId.trim() || !secret.trim()) return;
    configSaver.running = true;
    configSaver.write(JSON.stringify({ discord_client_id: clientId.trim(), discord_client_secret: secret.trim() }) + "\n");
  }

  Process {
    id: bridge
    running: false
    stdinEnabled: true
    command: root.pluginApi ? ["python3", root.pluginApi.pluginDir + "/scripts/discord-ipc.py"] : ["true"]
    stdout: SplitParser {
      onRead: function(line) {
        if (!line.trim()) return;
        try { root._handleEvent(JSON.parse(line)); }
        catch(e) { Logger.w("Discord", "parse error:", e); }
      }
    }
    onExited: function(code) {
      root.discordConnected = false;
      if (code !== 0) retryTimer.restart();
    }
  }

  Timer { id: retryTimer; interval: 5000; repeat: false; onTriggered: { if (root.pluginApi && !bridge.running) _startBridge(); } }

  function _startBridge() {
    _resetState();
    if (!bridge.running) bridge.running = true;
  }

  function _resetState() {
    discordConnected = false; discordNeedsSetup = false; discordNeedsAuth = false;
    discordSetupMessage = ""; discordUsername = ""; discordUserId = "";
    voiceChannelName = ""; voiceParticipants = [];
    discordSelfMuted = false; discordSelfDeafened = false;
    guilds = []; guildChannels = {}; guildsLoading = false; channelsLoading = {};
  }

  function _setSpeaking(userId, speaking) {
    var p = voiceParticipants.slice();
    for (var i = 0; i < p.length; i++) { if (p[i].id === userId) { p[i].speaking = speaking; break; } }
    voiceParticipants = p;
  }

  function _makeParticipant(data) {
    var userId = data.user?.id || "";
    var hash   = data.user?.avatar || "";
    var disc   = data.user?.discriminator || "0";
    return {
      id: userId,
      nick: data.nick || data.user?.global_name || data.user?.username || "Unknown",
      avatarUrl: hash
        ? ("https://cdn.discordapp.com/avatars/" + userId + "/" + hash + ".png?size=64")
        : ("https://cdn.discordapp.com/embed/avatars/" + (parseInt(disc) % 5) + ".png"),
      speaking: false,
      mute: data.voice_state?.mute || data.voice_state?.self_mute || false,
      deaf: data.voice_state?.deaf || data.voice_state?.self_deaf || false,
    };
  }

  function _handleEvent(msg) {
    var d = msg.data || {};
    switch (msg.type) {
      case "connected":
        discordConnected = true; discordNeedsAuth = false; discordNeedsSetup = false;
        discordUsername = d.username || ""; discordUserId = d.user_id || "";
        break;
      case "disconnected":
        discordConnected = false; voiceChannelName = ""; voiceParticipants = [];
        guilds = []; guildChannels = {}; guildsLoading = false; channelsLoading = {};
        break;
      case "needs_setup": discordNeedsSetup = true; discordSetupMessage = d.message || ""; break;
      case "needs_auth": discordNeedsAuth  = true; discordSetupMessage = d.message || ""; break;
      case "error": discordConnected  = false; Logger.w("Discord", d.message); break;
      case "VOICE_CHANNEL_SELECT":
        voiceChannelName = d.channel_name || "";
        if (!d.channel_id) voiceParticipants = [];
        break;
      case "VOICE_STATE_CREATE": {
        var p = _makeParticipant(d);
        if (p.id === discordUserId) { discordSelfMuted = p.mute; discordSelfDeafened = p.deaf; }
        voiceParticipants = voiceParticipants.concat([p]);
        break;
      }
      case "VOICE_STATE_UPDATE": {
        var p2 = _makeParticipant(d); var uid = d.user?.id || "";
        if (uid === discordUserId) { discordSelfMuted = p2.mute; discordSelfDeafened = p2.deaf; }
        voiceParticipants = voiceParticipants.map(function(x){ return x.id === uid ? p2 : x; });
        break;
      }
      case "VOICE_STATE_DELETE":
        voiceParticipants = voiceParticipants.filter(function(p){ return p.id !== (d.user?.id||""); });
        break;
      case "SPEAKING_START": _setSpeaking(d.user_id || "", true);  break;
      case "SPEAKING_STOP": _setSpeaking(d.user_id || "", false); break;
      case "guilds":
        guilds = d.guilds || []; guildsLoading = false; break;
      case "channels": {
        var g = d.guild_id || "";
        guildChannels = Object.assign({}, guildChannels, { [g]: d.channels || [] });
        var cl = Object.assign({}, channelsLoading); delete cl[g]; channelsLoading = cl;
        break;
      }
    }
  }

  // Public functions (called from UI)
  function toggleMute()        { bridge.write(JSON.stringify({ action: "mute",         value: !discordSelfMuted })    + "\n"); }
  function toggleDeafen()      { bridge.write(JSON.stringify({ action: "deafen",       value: !discordSelfDeafened }) + "\n"); }
  function disconnectFromVoice(){ bridge.write(JSON.stringify({ action: "disconnect" })                               + "\n"); }
  function loadGuilds()        {
    if (guildsLoading) return; guildsLoading = true;
    bridge.write(JSON.stringify({ action: "get_guilds" }) + "\n");
  }
  function loadChannels(guildId) {
    if (!guildId || channelsLoading[guildId]) return;
    channelsLoading = Object.assign({}, channelsLoading, { [guildId]: true });
    bridge.write(JSON.stringify({ action: "get_channels", guild_id: guildId }) + "\n");
  }
  function joinChannel(channelId) { bridge.write(JSON.stringify({ action: "join_channel", channel_id: channelId }) + "\n"); }

  // Local UI state
  property int    browseTab: 0
  property string selectedGuildId: ""

  readonly property var currentChannels: {
    if (!selectedGuildId) return [];
    return (guildChannels[selectedGuildId] || []).slice()
           .sort(function(a,b){ return a.position - b.position; });
  }

  // Sizing
  implicitWidth: 300
  implicitHeight: discordCol.implicitHeight + Style.marginL * 2
  width: implicitWidth
  height: implicitHeight
  Behavior on implicitHeight { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

  // Background
  Rectangle {
    anchors.fill: parent
    color: root.panelsVisible ? Color.mSurface : "transparent"
    border.color: root.panelsVisible ? Color.mOutline : "transparent"
    border.width: root.panelsVisible ? 1 : 0
    radius: Style.radiusL; clip: false
  }

  ColumnLayout {
    id: discordCol
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginL }
    spacing: Style.marginS

    NBox {
      id: discordTitleBox
      Layout.fillWidth: true; visible: root.panelsVisible
      implicitHeight: titleRow.implicitHeight + Style.margin2S
      RowLayout {
        id: titleRow
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: Style.marginS }
        spacing: Style.marginXS
        NIcon { icon: "brand-discord"; pointSize: Style.fontSizeL; color: Color.mPrimary; applyUiScale: false }
        NText { Layout.fillWidth: true; text: "Discord"; pointSize: Style.fontSizeM; font.weight: Style.fontWeightSemiBold; color: Color.mOnSurface }
      }
    }

    NBox {
      Layout.fillWidth: true
      implicitHeight: dInner.implicitHeight + Style.margin2S
      color: root.panelsVisible ? Color.mSurfaceVariant : "transparent"
      border.color: root.panelsVisible ? Style.boxBorderColor  : "transparent"

      ColumnLayout {
        id: dInner
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginS }
        spacing: Style.marginXS

        RowLayout {
          id: discordHeader; visible: root.panelsVisible
          Layout.fillWidth: true; spacing: Style.marginXS
          NIcon { icon: "brand-discord"; pointSize: Style.fontSizeL; applyUiScale: false
            color: root.discordConnected ? Color.mPrimary : Color.mOnSurfaceVariant
            opacity: root.discordNeedsAuth ? 0.6 : 1.0; Behavior on opacity { NumberAnimation { duration: 200 } } }
          NText { Layout.fillWidth: true; text: root.voiceStatusText; pointSize: Style.fontSizeS
            font.weight: Style.fontWeightSemiBold
            color: root.discordConnected ? Color.mOnSurface : Color.mOnSurfaceVariant; elide: Text.ElideRight }
          Row {
            visible: root.discordConnected && !root.discordNeedsSetup && !root.settingsOpen; spacing: 2
            Repeater {
              model: ["Voice", "Browse"]
              delegate: Rectangle {
                required property string modelData; required property int index
                height: Style.fontSizeS * 1.6; width: tabLbl.implicitWidth + Style.marginS * 2; radius: Style.radiusS
                color: index >= 0 && root.browseTab === index ? Color.mPrimary : "transparent"
                NText { id: tabLbl; anchors.centerIn: parent; text: modelData; pointSize: Style.fontSizeXS
                  color: index >= 0 && root.browseTab === index ? Color.mOnPrimary : Color.mOnSurfaceVariant
                  font.weight: (index >= 0 && root.browseTab === index) ? Style.fontWeightSemiBold : Font.Normal }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                  onClicked: { if (index < 0) return; root.browseTab = index; if (index===1 && root.guilds.length===0) root.loadGuilds(); } }
              }
            }
          }
          NIconButton {
            visible: root.panelsVisible
            icon: "settings"
            baseSize: Style.baseWidgetSize * 0.75
            colorFg: root.settingsOpen ? Color.mPrimary : Color.mOnSurfaceVariant
            colorBg: root.settingsOpen ? Qt.alpha(Color.mPrimary, 0.12) : "transparent"
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }

        // Credential setup form
        ColumnLayout {
          visible: root.panelsVisible && (root.discordNeedsSetup || root.settingsOpen)
          Layout.fillWidth: true; spacing: Style.marginS

          NText {
            visible: root.discordNeedsSetup
            Layout.fillWidth: true
            text: "Discord credentials required.\nCreate an app at discord.com/developers/applications,\nenable RPC, then enter the credentials below."
            pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant; wrapMode: Text.WordWrap
          }

          ColumnLayout { Layout.fillWidth: true; spacing: Style.marginXS
            NText { text: "Client ID"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
            TextField {
              id: clientIdField; Layout.fillWidth: true
              placeholderText: "000000000000000000"
              placeholderTextColor: Color.mSecondary
              font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
              background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
            }
          }

          ColumnLayout { Layout.fillWidth: true; spacing: Style.marginXS
            NText { text: "Client Secret"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
            TextField {
              id: clientSecretField; Layout.fillWidth: true
              placeholderText: "xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
              placeholderTextColor: Color.mSecondary
              echoMode: TextInput.Password
              font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
              background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
            }
          }

          RowLayout { Layout.fillWidth: true; spacing: Style.marginXS
            Item { Layout.fillWidth: true }
            NIconButton {
              visible: !root.discordNeedsSetup
              icon: "x"; baseSize: Style.baseWidgetSize * 0.8
              onClicked: root.settingsOpen = false
            }
            NIconButton {
              icon: "check"; baseSize: Style.baseWidgetSize * 0.8
              colorFg: Color.mPrimary; colorBg: Qt.alpha(Color.mPrimary, 0.12)
              enabled: clientIdField.text.trim() !== "" && clientSecretField.text.trim() !== ""
              onClicked: root.saveCredentials(clientIdField.text, clientSecretField.text)
            }
          }
        }

        NText { visible: root.panelsVisible && root.discordNeedsAuth && !root.discordNeedsSetup && !root.settingsOpen
          Layout.fillWidth: true; text: "Approve in Discord's authorization dialog"
          pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant; wrapMode: Text.WordWrap }

        ColumnLayout {
          visible: root.browseTab === 0 || !root.panelsVisible
          Layout.fillWidth: true; spacing: Style.marginXS

          Item {
            visible: !root.panelsVisible; Layout.fillWidth: true
            implicitHeight: discordTitleBox.implicitHeight + Style.marginS + discordHeader.implicitHeight
          }

          Repeater {
            model: root.voiceParticipants
            delegate: RowLayout {
              required property var modelData; Layout.fillWidth: true; spacing: Style.marginS
              Item {
                id: avItem; readonly property int sz: Math.round(28*Style.uiScaleRatio); width: sz; height: sz
                Rectangle { anchors.fill: parent; radius: avItem.sz/2; color: Color.mSurfaceVariant
                  NText { anchors.centerIn: parent; text: (modelData.nick||"?")[0].toUpperCase(); pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant } }
                NImageRounded { id: avImg; anchors.fill: parent; radius: avItem.sz/2; imagePath: modelData.avatarUrl||"" }
                Rectangle { anchors.fill: parent; radius: avItem.sz/2; color: "transparent"; border.width: 2
                  border.color: modelData.speaking ? Color.mPrimary : "transparent"; Behavior on border.color { ColorAnimation { duration: 80 } } }
              }
              NText { Layout.fillWidth: true; text: modelData.nick; pointSize: Style.fontSizeS
                color: modelData.speaking ? Color.mPrimary : Color.mOnSurface; elide: Text.ElideRight
                Behavior on color { ColorAnimation { duration: 80 } } }
              NIcon { visible: modelData.mute||modelData.deaf; icon: modelData.deaf?"headphones-off":"microphone-off"
                pointSize: Style.fontSizeS; color: Color.mOnSurfaceVariant; applyUiScale: false }
            }
          }

          RowLayout {
            visible: root.panelsVisible && root.discordInVoice
            Layout.fillWidth: true; Layout.topMargin: Style.marginXS; spacing: Style.marginXS
            NIconButton { icon: root.discordSelfMuted?"microphone-off":"microphone"
              colorFg: root.discordSelfMuted?Color.mError:Color.mOnSurface
              colorBg: root.discordSelfMuted?Qt.alpha(Color.mError,0.15):Style.capsuleColor
              onClicked: root.toggleMute() }
            NIconButton { icon: root.discordSelfDeafened?"headphones-off":"headphones"
              colorFg: root.discordSelfDeafened?Color.mError:Color.mOnSurface
              colorBg: root.discordSelfDeafened?Qt.alpha(Color.mError,0.15):Style.capsuleColor
              onClicked: root.toggleDeafen() }
            NIconButton {
              icon: root.voiceHudPinned ? "pin-filled" : "pin"
              tooltipText: root.voiceHudPinned ? "Unpin voice HUD" : "Pin voice HUD on close"
              colorFg: root.voiceHudPinned ? Color.mPrimary : Color.mOnSurface
              colorBg: root.voiceHudPinned ? Qt.alpha(Color.mPrimary, 0.15) : Style.capsuleColor
              onClicked: root.voiceHudPinned = !root.voiceHudPinned }
            Item { Layout.fillWidth: true }
            NIconButton { icon: "phone-off"; colorFg: Color.mError; colorBg: Qt.alpha(Color.mError,0.15); onClicked: root.disconnectFromVoice() }
          }
        }

        ColumnLayout {
          visible: root.panelsVisible && root.browseTab===1; Layout.fillWidth: true; spacing: Style.marginXS
          NText { visible: root.guildsLoading && root.guilds.length===0; Layout.fillWidth: true; text: "Loading servers..."; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant; horizontalAlignment: Text.AlignHCenter }
          Flickable {
            visible: root.guilds.length > 0; Layout.fillWidth: true
            implicitHeight: Math.min(sCol.implicitHeight, Math.round(180*Style.uiScaleRatio)); contentHeight: sCol.implicitHeight; clip: true
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            Column { id: sCol; width: parent.width; spacing: 2
              Repeater {
                model: root.guilds
                delegate: Rectangle {
                  required property var modelData; readonly property bool sel: root.selectedGuildId===modelData.id
                  width: sCol.width; implicitHeight: sRowL.implicitHeight+Style.marginXXS*2; height: implicitHeight; radius: Style.radiusS
                  color: sel?Qt.alpha(Color.mPrimary,0.18):(sHov.containsMouse?Qt.alpha(Color.mPrimary,0.08):"transparent"); Behavior on color{ColorAnimation{duration:100}}
                  RowLayout { id: sRowL; anchors{left:parent.left;right:parent.right;verticalCenter:parent.verticalCenter;leftMargin:Style.marginXS;rightMargin:Style.marginXS} spacing:Style.marginS
                    Item { readonly property int sz: Math.round(28*Style.uiScaleRatio); property real iconRadius: parent.parent.sel?Style.radiusS:sz/2; width:sz;height:sz
                      Behavior on iconRadius { NumberAnimation { duration: 150 } }
                      Rectangle { anchors.fill:parent; radius:parent.iconRadius; color:Color.mSurfaceVariant
                        NText{anchors.centerIn:parent;text:(modelData.name||"?")[0].toUpperCase();pointSize:Style.fontSizeXS;font.weight:Style.fontWeightSemiBold;color:Color.mOnSurfaceVariant} }
                      NImageRounded{id:gIco;anchors.fill:parent;radius:parent.iconRadius;imagePath:modelData.icon_url||""}
                    }
                    NText{Layout.fillWidth:true;text:modelData.name||"";pointSize:Style.fontSizeS;color:parent.parent.sel?Color.mPrimary:Color.mOnSurface;elide:Text.ElideRight;font.weight:parent.parent.sel?Style.fontWeightSemiBold:Font.Normal}
                  }
                  MouseArea{id:sHov;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor;onClicked:{root.selectedGuildId=modelData.id;root.loadChannels(modelData.id);}}
                }
              }
            }
          }
          NText{visible:root.selectedGuildId!==""&&(root.channelsLoading[root.selectedGuildId]??false)&&(root.guildChannels[root.selectedGuildId]?.length??0)===0;Layout.fillWidth:true;text:"Loading channels...";pointSize:Style.fontSizeXS;color:Color.mOnSurfaceVariant;horizontalAlignment:Text.AlignHCenter}
          Flickable{visible:root.currentChannels.length>0;Layout.fillWidth:true;implicitHeight:Math.min(cCol.implicitHeight,Math.round(220*Style.uiScaleRatio));contentHeight:cCol.implicitHeight;clip:true;ScrollBar.vertical:ScrollBar{policy:ScrollBar.AsNeeded}
            Column{id:cCol;width:parent.width;spacing:0
              Repeater{model:root.currentChannels;delegate:Item{
                required property var modelData;readonly property bool isCat:modelData.type===4;readonly property bool isVoice:modelData.type===2||modelData.type===13
                width:cCol.width;visible:isCat||isVoice;implicitHeight:isCat?cLbl.implicitHeight+Style.marginXS:(isVoice?cRow.implicitHeight+Style.marginXXS*2:0)
                NText{id:cLbl;visible:isCat;anchors{left:parent.left;right:parent.right;top:parent.top;topMargin:Style.marginXS;leftMargin:Style.marginXS}text:modelData.name.toUpperCase();pointSize:Style.fontSizeXXS;font.weight:Style.fontWeightSemiBold;color:Color.mOnSurfaceVariant}
                Rectangle{id:cRow;visible:isVoice;anchors{left:parent.left;right:parent.right;verticalCenter:parent.verticalCenter}implicitHeight:cRL.implicitHeight+Style.marginXXS*2;height:implicitHeight;radius:Style.radiusS;color:cHov.containsMouse?Qt.alpha(Color.mPrimary,0.08):"transparent"
                  RowLayout{id:cRL;anchors{left:parent.left;right:parent.right;verticalCenter:parent.verticalCenter;leftMargin:Style.marginXS;rightMargin:Style.marginXS}spacing:Style.marginXS
                    NIcon{icon:modelData.type===13?"broadcast":"volume";pointSize:Style.fontSizeS;color:Color.mOnSurfaceVariant;applyUiScale:false}
                    NText{Layout.fillWidth:true;text:modelData.name;pointSize:Style.fontSizeS;color:Color.mOnSurface;elide:Text.ElideRight}
                  }
                  MouseArea{id:cHov;anchors.fill:parent;hoverEnabled:true;cursorShape:Qt.PointingHandCursor;onClicked:{root.joinChannel(modelData.id);root.browseTab=0;}}
                }
              }}
            }
          }
          NText{visible:root.selectedGuildId==="";Layout.fillWidth:true;text:"Select a server above";pointSize:Style.fontSizeXS;color:Color.mOnSurfaceVariant;horizontalAlignment:Text.AlignHCenter}
        }
      }
    }
  }
}

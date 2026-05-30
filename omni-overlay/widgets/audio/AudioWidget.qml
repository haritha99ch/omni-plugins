import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Services.Pipewire
import Quickshell.Widgets
import qs.Commons
import qs.Services.Media
import qs.Services.UI
import qs.Widgets

Item {
  id: root
  property var  pluginApi: null
  property bool panelsVisible: true
  property bool active: true

  // Audio state
  property real localOutputVolume: 0
  property bool localOutputVolumeChanging: false
  property int  lastSinkId: -1
  property real localInputVolume: 0
  property bool localInputVolumeChanging: false
  property int  lastSourceId: -1
  readonly property bool outputVolumeGuard: outputVolumeSlider.sliderActive || localOutputVolumeChanging
  readonly property bool inputVolumeGuard: inputVolumeSlider.sliderActive  || localInputVolumeChanging
  property int audioTab: 0

  Component.onCompleted: {
    var v = AudioService.volume;         localOutputVolume = (!isNaN(v)&&v!==undefined)?v:0;
    var iv = AudioService.inputVolume;   localInputVolume  = (!isNaN(iv)&&iv!==undefined)?iv:0;
    if (AudioService.sink)   lastSinkId   = AudioService.sink.id;
    if (AudioService.source) lastSourceId = AudioService.source.id;
  }

  Connections {
    target: AudioService
    function onSinkChanged() {
      if (AudioService.sink&&AudioService.sink.id!==root.lastSinkId) { root.lastSinkId=AudioService.sink.id; var v=AudioService.volume; root.localOutputVolume=(!isNaN(v)&&v!==undefined)?v:0; }
      else if (!AudioService.sink) { root.lastSinkId=-1; root.localOutputVolume=0; }
    }
    function onSourceChanged() {
      if (AudioService.source&&AudioService.source.id!==root.lastSourceId) { root.lastSourceId=AudioService.source.id; var v=AudioService.inputVolume; root.localInputVolume=(!isNaN(v)&&v!==undefined)?v:0; }
      else if (!AudioService.source) { root.lastSourceId=-1; root.localInputVolume=0; }
    }
    function onVolumeChanged() {
      if (!root.outputVolumeGuard&&!AudioService.isSettingOutputVolume&&AudioService.sink&&AudioService.sink.id===root.lastSinkId) { var v=AudioService.volume; root.localOutputVolume=(!isNaN(v)&&v!==undefined)?v:0; }
    }
    function onInputVolumeChanged() {
      if (!root.inputVolumeGuard&&!AudioService.isSettingInputVolume&&AudioService.source&&AudioService.source.id===root.lastSourceId) { var v=AudioService.inputVolume; root.localInputVolume=(!isNaN(v)&&v!==undefined)?v:0; }
    }
  }
  Connections { target: outputVolumeSlider; function onSliderActiveChanged() { if (!outputVolumeSlider.sliderActive&&AudioService.sink&&AudioService.sink.id===root.lastSinkId) { var v=AudioService.volume; root.localOutputVolume=(!isNaN(v)&&v!==undefined)?v:0; } } }
  Connections { target: inputVolumeSlider;  function onSliderActiveChanged() { if (!inputVolumeSlider.sliderActive&&AudioService.source&&AudioService.source.id===root.lastSourceId) { var v=AudioService.inputVolume; root.localInputVolume=(!isNaN(v)&&v!==undefined)?v:0; } } }

  Timer { interval: 100; running: root.outputVolumeGuard||root.inputVolumeGuard; repeat: true; onTriggered: {
    if (AudioService.sink&&AudioService.sink.id===root.lastSinkId&&Math.abs(root.localOutputVolume-AudioService.volume)>=0.01) AudioService.setVolume(root.localOutputVolume);
    if (AudioService.source&&AudioService.source.id===root.lastSourceId&&Math.abs(root.localInputVolume-AudioService.inputVolume)>=0.01) AudioService.setInputVolume(root.localInputVolume);
  }}

  implicitWidth: 400
  implicitHeight: Math.min(aRect.implicitHeight, parent?.height > 0 ? parent.height - y - 10 : 800)
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    id: aRect
    width: 400; implicitHeight: aCol.implicitHeight + Style.marginL*2; height: root.implicitHeight
    color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusL; clip: true

    ColumnLayout {
      id: aCol; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginL } spacing: Style.marginM
      NBox { Layout.fillWidth: true; implicitHeight: aHdr.implicitHeight+Style.margin2M
        RowLayout { id: aHdr; anchors.fill: parent; anchors.margins: Style.marginM; spacing: Style.marginM
          NIcon { icon: "settings-audio"; pointSize: Style.fontSizeXXL; color: Color.mPrimary }
          NText { text: "Audio"; pointSize: Style.fontSizeL; font.weight: Style.fontWeightBold; color: Color.mOnSurface; Layout.fillWidth: true }
        }
      }
      NTabBar { id: aTabBar; Layout.fillWidth: true; margins: Style.marginS; currentIndex: root.audioTab; distributeEvenly: true; onCurrentIndexChanged: root.audioTab=currentIndex
        NTabButton { text: "Volumes"; tabIndex: 0; checked: aTabBar.currentIndex===0 }
        NTabButton { text: "Devices"; tabIndex: 1; checked: aTabBar.currentIndex===1 }
      }

      ColumnLayout {
        visible: root.audioTab===0; Layout.fillWidth: true; spacing: Style.marginM
        NBox { Layout.fillWidth: true; implicitHeight: oC.implicitHeight+Style.margin2M
          ColumnLayout { id: oC; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginM } spacing: Style.marginM
            RowLayout { Layout.fillWidth: true; spacing: Style.marginXS; NText { text: "Output"; pointSize: Style.fontSizeM; color: Color.mPrimary } NText { text: AudioService.sink?"  -  "+(AudioService.sink.description||AudioService.sink.name||""):""; pointSize: Style.fontSizeS; color: Color.mOnSurfaceVariant; elide: Text.ElideRight; Layout.fillWidth: true } }
            RowLayout { Layout.fillWidth: true; spacing: Style.marginM
              NValueSlider { id: outputVolumeSlider; Layout.fillWidth: true; from: 0; to: Settings.data.audio.volumeOverdrive?1.5:1.0; value: root.localOutputVolume; stepSize: 0.01; heightRatio: 0.5; onMoved: function(v){root.localOutputVolume=v;} onPressedChanged: function(p){root.localOutputVolumeChanging=p;} }
              NText { text: Math.round((root.outputVolumeGuard?root.localOutputVolume:AudioService.volume)*100)+"%"; pointSize: Style.fontSizeM; font.family: Settings.data.ui.fontFixed; color: Color.mOnSurface; Layout.preferredWidth: 45*Style.uiScaleRatio; horizontalAlignment: Text.AlignRight }
              NIconButton { icon: AudioService.getOutputIcon(); baseSize: Style.baseWidgetSize*0.7; onClicked: { AudioService.suppressOutputOSD(); AudioService.setOutputMuted(!AudioService.muted); } }
            }
          }
        }
        NBox { Layout.fillWidth: true; implicitHeight: iC.implicitHeight+Style.margin2M
          ColumnLayout { id: iC; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginM } spacing: Style.marginM
            RowLayout { Layout.fillWidth: true; spacing: Style.marginXS; NText { text: "Input"; pointSize: Style.fontSizeM; color: Color.mPrimary } NText { text: AudioService.source?"  -  "+(AudioService.source.description||AudioService.source.name||""):""; pointSize: Style.fontSizeS; color: Color.mOnSurfaceVariant; elide: Text.ElideRight; Layout.fillWidth: true } }
            RowLayout { Layout.fillWidth: true; spacing: Style.marginM
              NValueSlider { id: inputVolumeSlider; Layout.fillWidth: true; from: 0; to: Settings.data.audio.volumeOverdrive?1.5:1.0; value: root.localInputVolume; stepSize: 0.01; heightRatio: 0.5; onMoved: function(v){root.localInputVolume=v;} onPressedChanged: function(p){root.localInputVolumeChanging=p;} }
              NText { text: Math.round((root.inputVolumeGuard?root.localInputVolume:AudioService.inputVolume)*100)+"%"; pointSize: Style.fontSizeM; font.family: Settings.data.ui.fontFixed; color: Color.mOnSurface; Layout.preferredWidth: 45*Style.uiScaleRatio; horizontalAlignment: Text.AlignRight }
              NIconButton { icon: AudioService.getInputIcon(); baseSize: Style.baseWidgetSize*0.7; onClicked: { AudioService.suppressInputOSD(); AudioService.setInputMuted(!AudioService.inputMuted); } }
            }
          }
        }
        PwObjectTracker { objects: (root.panelsVisible&&root.active) ? AudioService.appStreams : [] }
        Repeater {
          model: AudioService.appStreams
          delegate: NBox {
            id: appBox; required property PwNode modelData; Layout.fillWidth: true; implicitHeight: aRow.implicitHeight+Style.margin2M; visible: !isCap
            PwObjectTracker { objects: appBox.modelData?[appBox.modelData]:[] }
            property PwNodeAudio nodeAudio: (modelData&&modelData.audio)?modelData.audio:null
            property real appVol: (nodeAudio&&nodeAudio.volume!==undefined)?nodeAudio.volume:0.0
            property bool appMut: (nodeAudio&&nodeAudio.muted!==undefined)?nodeAudio.muted:false
            readonly property bool isCap: { if(!modelData||!modelData.properties)return false; var p=modelData.properties; if(p["stream.capture.sink"]!==undefined)return true; var mc=p["media.class"]||""; if(mc.includes("Capture")||mc==="Stream/Input"||mc==="Stream/Input/Audio")return true; return(p["media.role"]||"")==="Capture"; }
            readonly property string aName: { if(!modelData)return "Unknown"; var p=modelData.properties||{}; var bin=(p["application.process.binary"]||"").split("/").pop(); if(bin){var e=ThemeIcons.findAppEntry(bin.toLowerCase());if(e?.name)return e.name;} return p["application.name"]||modelData.description||modelData.name||"Unknown"; }
            readonly property string aIcon: { if(!modelData)return ""; var p=modelData.properties||{}; var bin=(p["application.process.binary"]||"").split("/").pop(); if(bin){var e=ThemeIcons.findAppEntry(bin.toLowerCase());if(e?.icon)return ThemeIcons.iconFromName(e.icon,"");} var ic=p["application.icon-name"]||""; if(ic&&ThemeIcons.iconExists(ic))return ThemeIcons.iconFromName(ic,""); return ThemeIcons.iconFromName("application-x-executable","application-x-executable"); }
            RowLayout { id: aRow; anchors.fill: parent; anchors.margins: Style.marginM; spacing: Style.marginM
              IconImage { Layout.preferredWidth: Style.baseWidgetSize; Layout.preferredHeight: Style.baseWidgetSize; source: appBox.aIcon; smooth: true; asynchronous: true; NIcon { anchors.fill: parent; icon: "apps"; pointSize: Style.fontSizeXL; color: Color.mPrimary; visible: parent.status===Image.Error||parent.status===Image.Null||appBox.aIcon==="" } }
              ColumnLayout { Layout.fillWidth: true; spacing: Style.marginXS
                NText { text: appBox.aName; pointSize: Style.fontSizeM; color: Color.mOnSurface; elide: Text.ElideRight; Layout.fillWidth: true }
                RowLayout { Layout.fillWidth: true; spacing: Style.marginM
                  NValueSlider { Layout.fillWidth: true; from: 0; to: Settings.data.audio.volumeOverdrive?1.5:1.0; value: appBox.appVol; stepSize: 0.01; heightRatio: 0.5; enabled: !!(appBox.nodeAudio&&appBox.modelData?.ready===true); onMoved: function(v){if(appBox.nodeAudio&&appBox.modelData?.ready===true){appBox.nodeAudio.volume=v;AudioService.setPanelAppStreamVolume(appBox.modelData,v);}} }
                  NText { text: Math.round(appBox.appVol*100)+"%"; pointSize: Style.fontSizeM; font.family: Settings.data.ui.fontFixed; color: Color.mOnSurface; Layout.preferredWidth: 45*Style.uiScaleRatio; horizontalAlignment: Text.AlignRight; enabled: !!(appBox.nodeAudio&&appBox.modelData?.ready===true) }
                  NIconButton { icon: appBox.appMut?"volume-mute":"volume-high"; baseSize: Style.baseWidgetSize*0.7; enabled: !!(appBox.nodeAudio&&appBox.modelData?.ready===true); onClicked: { if(appBox.nodeAudio&&appBox.modelData?.ready===true){var m=!appBox.appMut;appBox.nodeAudio.muted=m;AudioService.setPanelAppStreamMuted(appBox.modelData,m);}}}
                }
              }
            }
          }
        }
        NText { visible: AudioService.appStreams.length===0; Layout.fillWidth: true; text: "No app streams active"; pointSize: Style.fontSizeM; color: Color.mOnSurfaceVariant; horizontalAlignment: Text.AlignHCenter; Layout.topMargin: Style.marginS }
      }

      ColumnLayout {
        visible: root.audioTab===1; Layout.fillWidth: true; spacing: Style.marginM
        NBox { Layout.fillWidth: true; implicitHeight: oDev.implicitHeight+Style.margin2M
          ColumnLayout { id: oDev; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginM } spacing: Style.marginS
            NText { text: "Output Device"; pointSize: Style.fontSizeL; color: Color.mPrimary }
            ButtonGroup { id: sinks }
            Repeater { model: AudioService.sinks; NRadioButton { ButtonGroup.group: sinks; required property PwNode modelData; pointSize: Style.fontSizeS; text: modelData.description; Layout.fillWidth: true; checked: AudioService.sink?.id===modelData.id; onClicked: { AudioService.setAudioSink(modelData); root.localOutputVolume=AudioService.volume; } } }
          }
        }
        NBox { Layout.fillWidth: true; implicitHeight: iDev.implicitHeight+Style.margin2M
          ColumnLayout { id: iDev; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginM } spacing: Style.marginS
            NText { text: "Input Device"; pointSize: Style.fontSizeL; color: Color.mPrimary }
            ButtonGroup { id: sources }
            Repeater { model: AudioService.sources; NRadioButton { ButtonGroup.group: sources; required property PwNode modelData; pointSize: Style.fontSizeS; text: modelData.description; Layout.fillWidth: true; checked: AudioService.source?.id===modelData.id; onClicked: AudioService.setAudioSource(modelData) } }
          }
        }
      }
    }
  }
}

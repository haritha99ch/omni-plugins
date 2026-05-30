// OmniOverlayWindow  -  dynamic widget container.
//
// To add a widget:
//   1. Create  widgets/<id>/YourWidget.qml
//   2. Create  widgets/<id>/manifest.json  (see existing widgets for schema)
//   Done. No changes needed in this file.
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Services.Compositor
import qs.Services.Hardware
import qs.Services.UI
import qs.Widgets

PanelWindow {
  id: root
  property var pluginApi: null

  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: "omni-overlay-panels"
  WlrLayershell.exclusionMode: ExclusionMode.Ignore
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
  WlrLayershell.anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"

  mask: Region {
    x: root.clickThrough ? islandBg.x : 0
    y: root.clickThrough ? islandBg.y : 0
    width: root.panelsVisible ? (root.clickThrough ? islandBg.width : root.width) : 0
    height: root.panelsVisible ? (root.clickThrough ? islandBg.height : root.height) : 0
  }

  property bool panelsVisible: true
  property bool showVoiceHud: false  // set by Main.qml  -  only the last-active screen shows voice HUD on close
  property bool clickThrough: false  // when true: island stays interactive, everything else passes clicks to game

  // Widget registry (discovered at runtime)
  property var widgetManifests: []    // [{id, name, file, iconSrc, iconFallback, defaultX, defaultY}]
  property var widgetInstances: ({})  // { id: QmlObject }
  property var widgetVisible: ({})  // { id: bool }   -  persisted
  property var widgetPinned: ({})  // { id: bool }   -  persisted

  function getWidget(id) { return widgetInstances[id] ?? null }

  // Island state
  property int  pillMode: 0
  property bool widgetMenuOpen: false
  property var  recentGames: []

  signal positionSaved(string key, int x, int y)

  // Persistence
  function _saveState() {
    if (!pluginApi) return;
    var s = Object.assign({}, pluginApi.pluginSettings);
    s.widgetVisible = root.widgetVisible;
    s.widgetPinned  = root.widgetPinned;
    s.pillMode      = root.pillMode;
    pluginApi.pluginSettings = s;
    pluginApi.saveSettings();
  }

  function _loadState() {
    var s = pluginApi?.pluginSettings ?? {};
    if (s.widgetVisible) root.widgetVisible = Object.assign({}, s.widgetVisible);
    if (s.widgetPinned)  root.widgetPinned  = Object.assign({}, s.widgetPinned);
    if (s.pillMode !== undefined) root.pillMode = s.pillMode;
  }

  onWidgetVisibleChanged: _saveState()
  onWidgetPinnedChanged: _saveState()
  onPillModeChanged: _saveState()

  function _toggleWidgetVisible(id) {
    var v = Object.assign({}, root.widgetVisible); v[id] = !(v[id] ?? true); root.widgetVisible = v;
    var inst = root.widgetInstances[id];
    if (inst) {
      var show = root.panelsVisible && (root.widgetVisible[id] ?? true);
      inst.visible = show;
      if (inst.active !== undefined) inst.active = show;
    }
  }

  function _togglePin(id) {
    var p = Object.assign({}, root.widgetPinned); p[id] = !(p[id] ?? true); root.widgetPinned = p;
  }

  onPanelsVisibleChanged: { if (!panelsVisible) root.clickThrough = false; _syncWidgetVisibility(); }
  onShowVoiceHudChanged: _syncWidgetVisibility()

  function _syncWidgetVisibility() {
    for (var id in root.widgetInstances) {
      var inst = root.widgetInstances[id];
      if (!inst) continue;
      var show = root.panelsVisible && (root.widgetVisible[id] ?? true);
      inst.visible = root.panelsVisible ? show
        : (root.showVoiceHud && (inst.persistWhenHidden ?? false));
      if (inst.active !== undefined) inst.active = show;
    }
  }

  // Widget discovery & loading
  property bool _widgetsLoaded: false
  property bool _positionsInitialized: false
  property bool _recentGamesFetched: false

  onPluginApiChanged: {
    if (!pluginApi) return;
    _loadState();
    if (!_widgetsLoaded) { _widgetsLoaded = true; _discoverWidgets(); }
    if (!_recentGamesFetched) { _recentGamesFetched = true; Qt.callLater(function(){ recentGamesProc.running = true; }); }
  }

  // Read all manifests from widgets/<id>/manifest.json
  Process {
    id: manifestReader
    running: false
    command: ["sh", "-c",
      "for d in " + (root.pluginApi ? root.pluginApi.pluginDir : "") + "/widgets/*/; do " +
      "[ -f \"$d/manifest.json\" ] && tr -d '\\n\\r' < \"$d/manifest.json\" && echo; done"]
    stdout: SplitParser {
      onRead: function(line) {
        line = line.trim();
        if (!line) return;
        try {
          var m = JSON.parse(line);
          if (m.id && m.file) {
            var mList = root.widgetManifests.slice();
            mList.push(m);
            root.widgetManifests = mList;
          }
        } catch(e) { Logger.w("OmniOverlay", "manifest parse error:", e, line); }
      }
    }
    onExited: Qt.callLater(root._instantiateWidgets)
  }

  function _discoverWidgets() {
    root.widgetManifests = [];
    manifestReader.running = true;
  }

  // Instantiate each discovered widget via Qt.createComponent (mirror of PluginService)
  function _instantiateWidgets() {
    for (var i = 0; i < root.widgetManifests.length; i++) {
      var m = root.widgetManifests[i];
      _loadWidget(m);
    }
    Qt.callLater(_initPositions);
  }

  function _loadWidget(manifest) {
    var widgetPath = root.pluginApi.pluginDir + "/widgets/" + manifest.id + "/" + manifest.file;
    var comp = Qt.createComponent("file://" + widgetPath);
    var doCreate = function() {
      if (comp.status === Component.Error) {
        Logger.e("OmniOverlay", "Widget load error [" + manifest.id + "]:", comp.errorString());
        return;
      }
      var inst = comp.createObject(widgetContainer, {
        pluginApi: Qt.binding(function(){ return root.pluginApi; }),
        panelsVisible: Qt.binding(function(){ return root.panelsVisible; }),
        visible: root.panelsVisible && (root.widgetVisible[manifest.id] ?? true)
      });
      if (!inst) { Logger.e("OmniOverlay", "Widget createObject failed:", manifest.id); return; }
      // Absorb clicks on the widget background so they don't reach the dim's dismiss MouseArea
      Qt.createQmlObject('import QtQuick; MouseArea { anchors.fill: parent; z: -1; acceptedButtons: Qt.AllButtons }', inst, "ClickAbsorber");
      // Inject drag
      _attachDrag(inst, manifest.id);
      var insts = Object.assign({}, root.widgetInstances);
      insts[manifest.id] = inst;
      root.widgetInstances = insts;
    };
    if (comp.status === Component.Ready) doCreate();
    else if (comp.status === Component.Error) doCreate();
    else comp.statusChanged.connect(function(){ doCreate(); }); // Loading -> handles ready or error
  }

  // Programmatically inject a DragHandler onto each widget instance
  function _attachDrag(item, id) {
    var dh = Qt.createQmlObject('
      import QtQuick
      DragHandler {
        acceptedModifiers: Qt.AltModifier
        acceptedButtons: Qt.LeftButton
        target: null
        cursorShape: active ? Qt.SizeAllCursor : Qt.ArrowCursor
      }', item, "DragHandler_" + id);

    var ox = 0, oy = 0;
    dh.grabChanged.connect(function(transition, point) {});
    dh.activeChanged.connect(function() {
      if (dh.active) { ox = item.x; oy = item.y; }
      else root.positionSaved(id, item.x, item.y);
    });
    dh.translationChanged.connect(function() {
      if (!dh.active) return;
      item.x = Math.max(0, Math.min(root.width  - item.width,  Math.round(ox + dh.translation.x)));
      item.y = Math.max(0, Math.min(root.height - item.height, Math.round(oy + dh.translation.y)));
    });
  }

  onWidthChanged: if (width  > 0 && _widgetsLoaded) _initPositions()
  onHeightChanged: if (height > 0 && _widgetsLoaded) _initPositions()

  function _initPositions() {
    if (_positionsInitialized || width <= 0 || height <= 0) return;
    if (Object.keys(root.widgetInstances).length === 0) return;
    _positionsInitialized = true;
    var s = pluginApi?.pluginSettings ?? {};
    for (var i = 0; i < root.widgetManifests.length; i++) {
      var m = root.widgetManifests[i];
      var inst = root.widgetInstances[m.id];
      if (!inst) continue;
      var key = m.id + "Panel";
      if (s[key]?.x !== undefined) {
        inst.x = s[key].x; inst.y = s[key].y;
      } else {
        // Default position from manifest
        var dx = m.defaultX, dy = m.defaultY;
        inst.x = (dx === "right") ? Math.max(0, width - inst.implicitWidth - 20) : 20;
        inst.y = (dy === "bottom") ? Math.max(0, height - inst.implicitHeight - 20) : (typeof dy === "number" ? dy : 50);
      }
    }
  }

  // Persist widget positions
  Connections {
    target: root
    function onPositionSaved(key, x, y) {
      if (!root.pluginApi) return;
      var s = Object.assign({}, root.pluginApi.pluginSettings);
      s[key + "Panel"] = { x: x, y: y };
      root.pluginApi.pluginSettings = s;
      root.pluginApi.saveSettings();
    }
  }

  // Recent games
  Process {
    id: recentGamesProc; running: false
    command: ["python3", root.pluginApi ? (root.pluginApi.pluginDir + "/scripts/steam-recent.py") : "/bin/true"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { var p = JSON.parse(text.trim()); if (Array.isArray(p)) root.recentGames = p; }
        catch(e) {}
      }
    }
  }

  // Layer 1  -  Dim (behind widgets and island, darkens the game)
  Rectangle {
    anchors.fill: parent; color: "black"
    opacity: root.panelsVisible ? 0.45 : 0.0
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    MouseArea {
      anchors.fill: parent
      enabled: root.panelsVisible && !root.clickThrough
      onClicked: pluginApi?.mainInstance?.closeOmniOverlay()
    }
  }

  // Layer 2  -  Widget panels (above dim, below island)
  Item { id: widgetContainer; anchors.fill: parent }

  // Island pill components
  component PillBtn: Rectangle {
    id: pb
    property string src: ""; property string fallbackIcon: ""; property string label: ""
    property bool active: false; property color activeColor: Color.mPrimary
    signal clicked()
    readonly property int bsz: Math.round(39 * Style.uiScaleRatio)
    readonly property int icz: Math.round(21 * Style.uiScaleRatio)
    width: bsz; height: bsz; radius: Style.radiusM
    color: active?Color.mPrimary:(phov.containsMouse?Qt.alpha(Color.mPrimary,0.35):Qt.alpha(Color.mPrimary,0.18))
    Behavior on color { ColorAnimation { duration: 120 } }
    IconImage { id: pimg; anchors.centerIn: parent; width: pb.icz; height: pb.icz; source: pb.src; smooth: true; asynchronous: true; visible: pb.src!==""&&status===Image.Ready }
    NIcon { anchors.centerIn: parent; icon: pb.fallbackIcon; pointSize: Style.fontSizeXL; applyUiScale: false; visible: pb.fallbackIcon!==""&&!pimg.visible; color: "white" }
    Rectangle { visible: pb.active; width: 12; height: 2; radius: 1; color: pb.activeColor; anchors { bottom: parent.bottom; bottomMargin: 4; horizontalCenter: parent.horizontalCenter } }
    MouseArea { id: phov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.clicked(); onEntered: if(pb.label)TooltipService.show(pb,pb.label); onExited: TooltipService.hide() }
  }

  component ShortcutSlot: Rectangle {
    id: ss
    property int slotIndex: 0; property string slotLabel: "Game"
    readonly property var gameData: root.recentGames.length>slotIndex?root.recentGames[slotIndex]:null
    readonly property bool hasGame: gameData!==null
    readonly property int bsz: Math.round(39*Style.uiScaleRatio)
    width: bsz; height: bsz; radius: Style.radiusM
    color: shov.containsMouse?Qt.alpha(Color.mOnSurface,hasGame?0.1:0.07):"transparent"
    border.color: hasGame?"transparent":Qt.alpha(Color.mOutline,0.55); border.width: hasGame?0:1; clip: true
    Behavior on color { ColorAnimation { duration: 100 } }
    Rectangle { anchors.fill: parent; visible: ss.hasGame; color: Qt.rgba(0.1,0.1,0.14,1); radius: parent.radius }
    Image { id: gameImg; anchors.centerIn: parent; width: Math.min(parent.width,parent.height)-Math.round(6*Style.uiScaleRatio); height: width; source: ss.gameData?.icon??""; fillMode: Image.PreserveAspectFit; asynchronous: true; smooth: true; visible: ss.hasGame&&status===Image.Ready }
    NText { anchors.centerIn: parent; visible: ss.hasGame&&gameImg.status!==Image.Ready; text: (ss.gameData?.name??"?")[0].toUpperCase(); pointSize: Style.fontSizeXL; color: Qt.rgba(1,1,1,0.3); font.weight: Style.fontWeightBold }
    Rectangle { anchors.centerIn: parent; visible: !ss.hasGame; readonly property int sz: Math.min(parent.width,parent.height)-Math.round(8*Style.uiScaleRatio); width: sz; height: sz; radius: Style.radiusS; color: "transparent"; border.color: Qt.alpha(Color.mOutline,0.55); border.width: 1; NIcon { anchors.centerIn: parent; icon: "plus"; pointSize: Style.fontSizeS; applyUiScale: false; color: Color.mOnSurfaceVariant; opacity: 0.4 } }
    MouseArea { id: shov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { if(ss.hasGame&&ss.gameData?.url)Qt.openUrlExternally(ss.gameData.url); } onEntered: TooltipService.show(ss,ss.hasGame?(ss.gameData?.name??""):"Add game shortcut"); onExited: TooltipService.hide() }
  }

  // DYNAMIC ISLAND
  Rectangle {
    id: islandBg
    visible: root.panelsVisible
    MouseArea { anchors.fill: parent; z: -1; acceptedButtons: Qt.AllButtons }
    width: Math.max(wsInner.implicitWidth, ctrlInner.implicitWidth) + Style.marginM*2
    height: islandCol.implicitHeight + Style.marginS*2
    x: Math.round((root.width - width) / 2); y: 10
    radius: Style.radiusL; color: Qt.alpha(Color.mSurface,0.97); border.color: Color.mOutline; border.width: 1
      Behavior on width  { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
      layer.enabled: true
      layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.5; shadowOpacity: 0.4; shadowColor: "black"; shadowVerticalOffset: 4; blurMax: 24 }

      Column {
        id: islandCol
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginS }
        spacing: 0

        // Workspace dots
        Item {
          width: parent.width; height: Math.round(22*Style.uiScaleRatio)
          Row {
            id: wsInner; anchors.centerIn: parent; spacing: Math.round(4*Style.uiScaleRatio)
            Repeater {
              model: CompositorService.workspaces
              delegate: Item {
                required property var modelData
                readonly property bool focused: modelData.isFocused; readonly property bool occupied: modelData.isOccupied
                visible: modelData.output?.toLowerCase()===root.screen?.name?.toLowerCase()
                width: visible?(focused?Math.round(28*Style.uiScaleRatio):Math.round(14*Style.uiScaleRatio)):0; height: Math.round(14*Style.uiScaleRatio)
                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Rectangle { anchors.fill: parent; radius: height/2; color: focused?Color.mPrimary:occupied?Qt.alpha(Color.mOnSurface,0.45):Qt.alpha(Color.mOnSurface,0.18); Behavior on color{ColorAnimation{duration:150}}
                  NText { anchors.centerIn: parent; visible: parent.parent.focused; text: modelData.idx?.toString()??""; pointSize: Style.fontSizeXXS; font.weight: Style.fontWeightSemiBold; color: Color.mOnPrimary }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; visible: parent.visible; onClicked: CompositorService.switchToWorkspace(modelData); onEntered: TooltipService.show(parent,"Workspace "+(modelData.idx??"")); onExited: TooltipService.hide() }
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: Color.mOutline; opacity: 0.5 }

        // Controls row  -  driven entirely by widgetManifests (no hardcoded widget names)
        Item {
          width: parent.width; height: Math.round(51*Style.uiScaleRatio)
          Row {
            id: ctrlInner; anchors.centerIn: parent; spacing: Style.marginXS

            // Mode toggle + widget menu
            PillBtn { src: root.pillMode===0?"file:///usr/share/icons/hicolor/scalable/apps/input-gaming.svg":""; fallbackIcon: root.pillMode===0?"device-gamepad-2":"home"; label: root.pillMode===0?"Shortcuts":"Home"; active: true; activeColor: Color.mPrimary; onClicked: root.pillMode=root.pillMode===0?1:0 }
            PillBtn { fallbackIcon: "apps"; label: "Widgets"; active: root.widgetMenuOpen; activeColor: Color.mPrimary; onClicked: root.widgetMenuOpen=!root.widgetMenuOpen }
            Rectangle { width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }

            // Home mode: one button per discovered widget, pinned ones visible
            Repeater {
              model: root.pillMode===0 ? root.widgetManifests : []
              delegate: PillBtn {
                required property var modelData
                visible: root.widgetPinned[modelData.id] ?? true
                src: modelData.iconSrc; fallbackIcon: modelData.iconFallback; label: modelData.name
                active: root.widgetVisible[modelData.id] ?? true
                onClicked: root._toggleWidgetVisible(modelData.id)
              }
            }

            // Shortcuts mode: recent game slots
            ShortcutSlot { visible: root.pillMode===1; slotIndex: 0; slotLabel: "Game 1" }
            ShortcutSlot { visible: root.pillMode===1; slotIndex: 1; slotLabel: "Game 2" }
            ShortcutSlot { visible: root.pillMode===1; slotIndex: 2; slotLabel: "Game 3" }

            Rectangle { width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }
            PillBtn { src: "file:///usr/share/icons/hicolor/48x48/apps/steam.png"; fallbackIcon: "brand-steam"; label: "Open Steam"; active: false; onClicked: Qt.openUrlExternally("steam://open/games") }

            // Clock + battery (home mode only)
            Rectangle { visible: root.pillMode===0; width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }
            Item { visible: root.pillMode===0; anchors.verticalCenter: parent?.verticalCenter; width: timeTxt.implicitWidth; height: timeTxt.implicitHeight
              NText { id: timeTxt; text: Qt.formatTime(new Date(),"h:mm AP"); pointSize: Style.fontSizeXL; font.weight: Style.fontWeightSemiBold; color: "white"
                Timer { interval: 10000; running: true; repeat: true; onTriggered: timeTxt.text=Qt.formatTime(new Date(),"h:mm AP") }
              }
            }
            Rectangle { visible: root.pillMode===0; width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }
            Row { visible: root.pillMode===0&&BatteryService.batteryPresent; anchors.verticalCenter: parent?.verticalCenter; spacing: Math.round(4*Style.uiScaleRatio)
              NIcon { anchors.verticalCenter: parent.verticalCenter; icon: BatteryService.batteryIcon; pointSize: Style.fontSizeXL; applyUiScale: false; color: BatteryService.batteryPercentage<=BatteryService.criticalThreshold?Color.mError:BatteryService.batteryCharging?Color.mPrimary:"white" }
              NText { anchors.verticalCenter: parent.verticalCenter; text: Math.round(BatteryService.batteryPercentage)+"%"; pointSize: Style.fontSizeL; font.weight: Style.fontWeightSemiBold; color: BatteryService.batteryPercentage<=BatteryService.criticalThreshold?Color.mError:"white" }
            }

            // Click-through toggle
            Rectangle { visible: root.pillMode===0; width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }
            PillBtn {
              visible: root.pillMode===0
              fallbackIcon: "mouse"
              label: root.clickThrough ? "Click-through on" : "Click-through off"
              active: root.clickThrough
              activeColor: Color.mPrimary
              onClicked: root.clickThrough = !root.clickThrough
            }
          }
        }

        // Widget menu  -  lists discovered widgets, no hardcoded entries
        Rectangle { width: parent.width; height: 1; visible: root.widgetMenuOpen; color: Color.mOutline; opacity: 0.5 }
        Column {
          visible: root.widgetMenuOpen; width: parent.width; spacing: 0
          Repeater {
            model: root.widgetManifests
            delegate: Rectangle {
              required property var modelData; required property int index
              width: parent.width; height: Math.round(42*Style.uiScaleRatio)
              color: wHov.containsMouse?Qt.alpha(Color.mOnSurface,0.06):"transparent"
              radius: index===root.widgetManifests.length-1?Style.radiusL:0
              Behavior on color { ColorAnimation { duration: 80 } }
              RowLayout {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.marginM; rightMargin: Style.marginS } spacing: Style.marginS
                IconImage { width: Math.round(20*Style.uiScaleRatio); height: width; source: modelData.iconSrc; smooth: true; asynchronous: true; opacity: 0.85 }
                NText { Layout.fillWidth: true; text: modelData.name; pointSize: Style.fontSizeS; color: Color.mOnSurface }
                Rectangle { width: 6; height: 6; radius: 3; color: (root.widgetVisible[modelData.id]??true)?Color.mPrimary:Qt.alpha(Color.mOnSurfaceVariant,0.3); Behavior on color{ColorAnimation{duration:120}} }
                Rectangle {
                  width: Math.round(28*Style.uiScaleRatio); height: width; radius: Style.radiusS
                  color: starHov.containsMouse?Qt.alpha(Color.mOnSurface,0.1):"transparent"; Behavior on color{ColorAnimation{duration:80}}
                  NIcon { anchors.centerIn: parent; icon: (root.widgetPinned[modelData.id]??true)?"star-filled":"star"; pointSize: Style.fontSizeM; applyUiScale: false; color: (root.widgetPinned[modelData.id]??true)?Color.mPrimary:Color.mOnSurfaceVariant; Behavior on color{ColorAnimation{duration:120}} }
                  MouseArea { id: starHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root._togglePin(modelData.id); onEntered: TooltipService.show(parent,(root.widgetPinned[modelData.id]??true)?"Unpin":"Pin to island"); onExited: TooltipService.hide() }
                }
              }
              MouseArea { id: wHov; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            }
          }
        }
      }
    }
  }


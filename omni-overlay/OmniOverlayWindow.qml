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
    // Island + widget panels only — apps in special:overlay-apps are always reachable.

    // Island
    Region {
      x: islandBg.x; y: islandBg.y
      width: root.panelsVisible ? islandBg.width : 0
      height: root.panelsVisible ? islandBg.height : 0
    }

    // Widget slots — bound by manifest index, no widget IDs hardcoded
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[0]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[1]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[2]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[3]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[4]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[5]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[6]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
    Region { readonly property var _i: root.widgetInstances[root.widgetManifests[7]?.id]; x: _i?.x??0; y: _i?.y??0; width: (_i?.visible&&root.panelsVisible)?(_i.width??0):0; height: (_i?.visible&&root.panelsVisible)?(_i.height??0):0 }
  }

  property bool panelsVisible: false
  property bool showVoiceHud: false  // set by Main.qml  -  only the last-active screen shows voice HUD on close
  property bool clickThrough: false  // toggles special_fallthrough via hyprctl — allows interacting with regular workspace behind overlay-apps

  // Widget registry (discovered at runtime)
  property var widgetManifests: []    // [{id, name, file, iconSrc, iconFallback, defaultX, defaultY}]
  property var widgetInstances: ({})  // { id: QmlObject }
  property var widgetVisible: ({})  // { id: bool }   -  persisted
  property var widgetPinned: ({})  // { id: bool }   -  persisted

  function getWidget(id) { return widgetInstances[id] ?? null }

  // Island state
  property int  pillMode: 0
  property bool widgetMenuOpen: false
  property bool settingsPanelOpen: false
  property bool shortcutsPanelOpen: false
  property var  recentGames: []
  property string steamPath: "~/.local/share/Steam"

  // Custom shortcuts  [{name, command, icon}]
  property var customShortcuts: []

  function _saveShortcuts() {
    if (!pluginApi) return;
    var s = Object.assign({}, pluginApi.pluginSettings);
    s.customShortcuts = root.customShortcuts;
    pluginApi.pluginSettings = s;
    pluginApi.saveSettings();
  }


  function addShortcut(name, command, icon) {
    if (!name.trim() || !command.trim()) return;
    root.customShortcuts = root.customShortcuts.concat([{
      name: name.trim(), command: command.trim(),
      icon: icon || "terminal-2",
      overlay: true
    }]);
    _saveShortcuts();
  }

  function removeShortcut(index) {
    var arr = root.customShortcuts.slice();
    arr.splice(index, 1);
    root.customShortcuts = arr;
    _saveShortcuts();
  }

  function _resolveCommand(cmd) {
    if (cmd.endsWith(".desktop")) {
      var appId = cmd.replace(/.*\//, "").replace(/\.desktop$/, "");
      return "gtk-launch " + appId;
    }
    return cmd;
  }

  // Resolve name/icon from .desktop then call callback(name, iconSrc)
  function _resolveDesktop(cmd, name, icon, callback) {
    if (!cmd.trim().endsWith(".desktop") || (name.trim() && icon.trim())) {
      callback(name, icon); return;
    }
    var script =
      "name=$(grep -m1 '^Name=' '" + cmd.trim() + "' | cut -d= -f2-); " +
      "ico=$(grep -m1 '^Icon=' '" + cmd.trim() + "' | cut -d= -f2-); " +
      "echo \"$name\"; " +
      "if [ -f \"$ico\" ]; then echo \"file://$ico\"; " +
      "else " +
      "  found=''; " +
      "  for size in 256 128 64 48 32 scalable; do " +
      "    for ext in png svg xpm; do " +
      "      f=\"/usr/share/icons/hicolor/$size/apps/$ico.$ext\"; " +
      "      [ -f \"$f\" ] && found=\"$f\" && break 2; " +
      "    done; " +
      "  done; " +
      "  [ -z \"$found\" ] && found=$(find /usr/share/pixmaps -maxdepth 1 -name \"$ico.*\" 2>/dev/null | head -1); " +
      "  [ -n \"$found\" ] && echo \"file://$found\" || echo \"$ico\"; " +
      "fi";
    var reader = Qt.createQmlObject(
      'import QtQuick; import Quickshell.Io; Process { command: ["sh","-c","' + script.replace(/"/g, '\\"') + '"]; running: true; stdout: StdioCollector {} }',
      root, "DesktopResolver");
    reader.exited.connect(function() {
      var lines = reader.stdout.text.trim().split("\n");
      var resolvedName = name.trim() || (lines[0] ? lines[0].trim() : cmd.replace(/.*\//, "").replace(/\.desktop$/, ""));
      var resolvedIcon = icon.trim() || (lines[1] ? lines[1].trim() : "app-window");
      reader.destroy();
      callback(resolvedName, resolvedIcon);
    });
  }

  function launchShortcut(shortcut) {
    var cmd = _resolveCommand(shortcut.command);
    if (shortcut.overlay) {
      _launchInOverlay(cmd);
    } else {
      var escaped = cmd.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
      Qt.createQmlObject(
        'import QtQuick; import Quickshell.Io; Process { command: ["sh","-c","' + escaped + '"]; running: true }',
        root, "Shortcut");
    }
  }

  function _launchInOverlay(command) {
    Qt.createQmlObject(
      'import QtQuick; import Quickshell.Io; Process { command: ["hyprctl","dispatch","exec","[workspace special:overlay-apps] ' + command.replace(/"/g, '\\"') + '"]; running: true }',
      root, "OverlayShortcut");
  }


  function _toggleOverlayApps(shouldShow) {
    var checker = Qt.createQmlObject(
      'import QtQuick; import Quickshell.Io; Process { command: ["hyprctl","monitors","-j"]; running: true; stdout: StdioCollector {} }',
      root, "MonCheck");
    checker.exited.connect(function() {
      try {
        var monitors = JSON.parse(checker.stdout.text);
        var isShowing = monitors.some(function(m){
          return m.specialWorkspace && m.specialWorkspace.name === "special:overlay-apps";
        });
        if (shouldShow !== isShowing)
          Qt.createQmlObject('import QtQuick; import Quickshell.Io; Process { command: ["hyprctl","dispatch","togglespecialworkspace","overlay-apps"]; running: true }', root, "Toggle");
        // Auto-manage special_fallthrough — no config change needed by the user
        Qt.createQmlObject('import QtQuick; import Quickshell.Io; Process { command: ["hyprctl","keyword","input:special_fallthrough","' + (shouldShow ? "false" : "true") + '"]; running: true }', root, "Fallthrough");
      } catch(e) {}
      checker.destroy();
    });
  }

  // Widget source / marketplace
  property var widgetSources: []        // [{name, url}]  -  persisted
  property var remoteWidgets: []        // [{id, name, description, version, author, iconFallback, sourceUrl}]
  property bool fetchingRegistry: false

  function isWidgetInstalled(id) {
    return root.widgetManifests.some(function(m){ return m.id === id; });
  }

  function _saveWidgetSources() {
    if (!pluginApi) return;
    var s = Object.assign({}, pluginApi.pluginSettings);
    s.widgetSources = root.widgetSources;
    // Remove so manifest default re-applies if list becomes empty
    if (!root.widgetSources || root.widgetSources.length === 0) delete s.widgetSources;
    pluginApi.pluginSettings = s;
    pluginApi.saveSettings();
  }

  function addWidgetSource(name, url) {
    if (!url.trim() || !name.trim()) return;
    var exists = root.widgetSources.some(function(s){ return s.url === url.trim(); });
    if (exists) return;
    root.widgetSources = root.widgetSources.concat([{ name: name.trim(), url: url.trim() }]);
    _saveWidgetSources();
    fetchRemoteWidgets();
  }

  function removeWidgetSource(url) {
    root.widgetSources = root.widgetSources.filter(function(s){ return s.url !== url; });
    _saveWidgetSources();
    root.remoteWidgets = root.remoteWidgets.filter(function(w){ return w.sourceUrl !== url; });
  }

  function fetchRemoteWidgets() {
    if (root.widgetSources.length === 0 || root.fetchingRegistry) return;
    root.fetchingRegistry = true;
    root.remoteWidgets = [];
    var remaining = root.widgetSources.length;
    root.widgetSources.forEach(function(src) {
      var proc = registryFetchTemplate.createObject(root, { sourceUrl: src.url });
      proc.onExited.connect(function(code) {
        remaining--;
        if (remaining === 0) root.fetchingRegistry = false;
        proc.destroy();
      });
      proc.running = true;
    });
  }

  function installWidget(remoteWidget) {
    if (!pluginApi) return;
    var wid = remoteWidget.id;
    var src = remoteWidget.sourceUrl;
    var dst = pluginApi.pluginDir + "/widgets";
    var repo = src.split("/").pop();
    var cmd = "mkdir -p '" + dst + "/" + wid + "' && " +
              "curl -sL '" + src + "/archive/refs/heads/main.tar.gz' | " +
              "tar -xzf - --strip-components=2 -C '" + dst + "/" + wid + "/' '" + repo + "-main/" + wid + "/'";

    var proc = Qt.createQmlObject(
      'import QtQuick; import Quickshell.Io; Process { command: ["sh", "-c", "' + cmd.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"] }',
      root, "WidgetInstaller_" + wid);
    if (!proc) { Logger.e("OmniOverlay", "installWidget: createObject failed"); return; }
    proc.exited.connect(function(code) {
      if (code === 0) {
        root.remoteWidgets = root.remoteWidgets.filter(function(w){ return w.id !== wid; });
        root._discoverWidgets();
      } else {
        Logger.e("OmniOverlay", "Widget install failed:", wid, "code:", code);
      }
      proc.destroy();
    });
    proc.running = true;
  }

  function removeWidget(id) {
    var proc = widgetRemoverTemplate.createObject(root, { widgetId: id });
    proc.running = true;
  }

  signal positionSaved(string key, int x, int y)

  // Persistence
  function _saveState() {
    if (!pluginApi) return;
    var s = Object.assign({}, pluginApi.pluginSettings);
    s.widgetVisible  = root.widgetVisible;
    s.widgetPinned   = root.widgetPinned;
    s.pillMode       = root.pillMode;
    s.steamPath      = root.steamPath;
    if (root.widgetSources && root.widgetSources.length > 0)
      s.widgetSources = root.widgetSources;
    else
      delete s.widgetSources;
    pluginApi.pluginSettings = s;
    pluginApi.saveSettings();
  }

  function _loadState() {
    var s = pluginApi?.pluginSettings ?? {};
    if (s.widgetVisible)  root.widgetVisible  = Object.assign({}, s.widgetVisible);
    if (s.widgetPinned)   root.widgetPinned   = Object.assign({}, s.widgetPinned);
    if (s.pillMode !== undefined) root.pillMode = s.pillMode;
    if (s.widgetSources)  root.widgetSources = s.widgetSources.slice();
    if (s.steamPath)      root.steamPath     = s.steamPath;
    if (s.customShortcuts)  root.customShortcuts  = s.customShortcuts.slice();
    Qt.callLater(fetchRemoteWidgets);
  }

  // Registry fetch — one instance per source (created dynamically)
  Component {
    id: registryFetchTemplate
    Process {
      property string sourceUrl: ""
      stdinEnabled: false
      command: ["sh", "-c",
        "tmp=$(mktemp -d) && GIT_TERMINAL_PROMPT=0 git clone --filter=blob:none --sparse --depth=1 --quiet '" + sourceUrl + "' \"$tmp\" 2>/dev/null && " +
        "cd \"$tmp\" && git sparse-checkout set --no-cone /registry.json 2>/dev/null && " +
        "tr -d '\\n\\r' < \"$tmp/registry.json\" && echo; rm -rf \"$tmp\""]
      stdout: SplitParser {
        onRead: function(line) {
          line = line.trim();
          if (!line) return;
          try {
            var reg = JSON.parse(line);
            var widgets = reg.widgets || [];
            var toAdd = widgets.filter(function(w){ return !root.isWidgetInstalled(w.id); });
            toAdd.forEach(function(w){ w.sourceUrl = sourceUrl; });
            root.remoteWidgets = root.remoteWidgets.concat(toAdd);
          } catch(e) {}
        }
      }
    }
  }

  // Widget remover
  Component {
    id: widgetRemoverTemplate
    Process {
      property string widgetId: ""
      readonly property string _widgetPath: root.pluginApi ? root.pluginApi.pluginDir + "/widgets/" + widgetId : ""
      command: ["sh", "-c", "rm -rf '" + _widgetPath + "'"]
      onExited: function(code) {
        var inst = root.widgetInstances[widgetId];
        if (inst) inst.destroy();
        var insts = Object.assign({}, root.widgetInstances);
        delete insts[widgetId];
        root.widgetInstances = insts;
        root.widgetManifests = root.widgetManifests.filter(function(m){ return m.id !== widgetId; });
        fetchRemoteWidgets();
        destroy();
      }
    }
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

  onPanelsVisibleChanged: {
    if (!panelsVisible) {
      root.clickThrough = false;
      Qt.createQmlObject('import QtQuick; import Quickshell.Io; Process { command: ["hyprctl","keyword","input:special_fallthrough","false"]; running: true }', root, "FallthroughReset");
    }
    _toggleOverlayApps(panelsVisible);
    _syncWidgetVisibility();
  }
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
    if (root.widgetInstances[manifest.id]) return;  // already loaded, skip
    var widgetPath = root.pluginApi.pluginDir + "/widgets/" + manifest.id + "/" + manifest.file;
    var comp = Qt.createComponent("file://" + widgetPath);
    var doCreate = function() {
      if (comp.status === Component.Error) {
        Logger.e("OmniOverlay", "Widget load error [" + manifest.id + "]:", comp.errorString());
        return;
      }
      if (root.widgetInstances[manifest.id]) return;  // guard against async double-load
      var inst = comp.createObject(widgetContainer, {
        pluginApi: Qt.binding(function(){ return root.pluginApi; }),
        panelsVisible: Qt.binding(function(){ return root.panelsVisible; }),
        visible: root.panelsVisible && (root.widgetVisible[manifest.id] ?? true)
      });
      if (!inst) { Logger.e("OmniOverlay", "Widget createObject failed:", manifest.id); return; }
      Qt.createQmlObject('import QtQuick; MouseArea { anchors.fill: parent; z: -1; acceptedButtons: Qt.AllButtons }', inst, "ClickAbsorber");
      _attachDrag(inst, manifest.id);
      var insts = Object.assign({}, root.widgetInstances);
      insts[manifest.id] = inst;
      root.widgetInstances = insts;
      _syncWidgetVisibility();  // ensure new widget gets correct visibility immediately
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
        acceptedModifiers: Qt.NoModifier
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
    command: root.pluginApi ? ["python3", root.pluginApi.pluginDir + "/scripts/steam-recent.py", root.steamPath] : ["true"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { var p = JSON.parse(text.trim()); if (Array.isArray(p)) root.recentGames = p; }
        catch(e) {}
      }
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
            id: ctrlInner; anchors.centerIn: parent; spacing: Style.marginS

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

            // Shortcuts mode: recent Steam game slots
            ShortcutSlot { visible: root.pillMode===1; slotIndex: 0; slotLabel: "Game 1" }
            ShortcutSlot { visible: root.pillMode===1; slotIndex: 1; slotLabel: "Game 2" }
            ShortcutSlot { visible: root.pillMode===1; slotIndex: 2; slotLabel: "Game 3" }

            // Custom shortcuts
            Rectangle { visible: root.pillMode===1 && root.customShortcuts.length>0; width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }
            Repeater {
              model: root.pillMode===1 ? root.customShortcuts : []
              delegate: PillBtn {
                required property var modelData
                readonly property bool _isFileIcon: (modelData.icon||"").startsWith("file://") || (modelData.icon||"").startsWith("http") || (modelData.icon||"").startsWith("image://")
                src: _isFileIcon ? modelData.icon : ""
                fallbackIcon: _isFileIcon ? "" : (modelData.icon || "terminal-2")
                label: modelData.name
                active: false
                onClicked: root.launchShortcut(modelData)
              }
            }
            PillBtn {
              visible: root.pillMode===1
              fallbackIcon: "plus"
              label: "Add shortcut"
              active: root.shortcutsPanelOpen
              activeColor: Color.mPrimary
              onClicked: root.shortcutsPanelOpen = !root.shortcutsPanelOpen
            }

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

            // Overlay apps toggle
            Rectangle { visible: root.pillMode===0; width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }
            PillBtn {
              visible: root.pillMode===0
              fallbackIcon: "mouse"
              label: root.clickThrough ? "Click-through on" : "Click-through off"
              active: root.clickThrough
              activeColor: Color.mPrimary
              onClicked: {
                root.clickThrough = !root.clickThrough;
                var val = root.clickThrough ? "true" : "false";
                Qt.createQmlObject('import QtQuick; import Quickshell.Io; Process { command: ["hyprctl","keyword","input:special_fallthrough","' + val + '"]; running: true }', root, "Fallthrough");
              }
            }

            // Widget settings
            Rectangle { visible: root.pillMode===0; width: 1; height: Math.round(30*Style.uiScaleRatio); color: Color.mOutline; opacity: 0.5; anchors.verticalCenter: parent?.verticalCenter }
            PillBtn {
              visible: root.pillMode===0
              fallbackIcon: "settings"
              label: "Widget settings"
              active: root.settingsPanelOpen
              activeColor: Color.mPrimary
              onClicked: { root.settingsPanelOpen = !root.settingsPanelOpen; if (root.settingsPanelOpen) root.widgetMenuOpen = false; }
            }
          }
        }

        // Widget menu  -  installed widgets + downloadable from sources
        Rectangle { width: parent.width; height: 1; visible: root.widgetMenuOpen; color: Color.mOutline; opacity: 0.5 }
        Column {
          visible: root.widgetMenuOpen; width: parent.width; spacing: 0

          // Installed widgets
          Repeater {
            model: root.widgetManifests
            delegate: Rectangle {
              required property var modelData; required property int index
              width: parent.width; height: Math.round(42*Style.uiScaleRatio)
              color: wHov.containsMouse?Qt.alpha(Color.mOnSurface,0.06):"transparent"
              Behavior on color { ColorAnimation { duration: 80 } }
              RowLayout {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.marginM; rightMargin: Style.marginS } spacing: Style.marginS
                IconImage { width: Math.round(20*Style.uiScaleRatio); height: width; source: modelData.iconSrc; smooth: true; asynchronous: true; opacity: 0.85 }
                NText { Layout.fillWidth: true; text: modelData.name; pointSize: Style.fontSizeS; color: Color.mOnSurface }
                Rectangle { width: 6; height: 6; radius: 3; color: (root.widgetVisible[modelData.id]??true)?Color.mPrimary:Qt.alpha(Color.mOnSurfaceVariant,0.3); Behavior on color{ColorAnimation{duration:120}} }
                // Pin / unpin
                Rectangle {
                  width: Math.round(28*Style.uiScaleRatio); height: width; radius: Style.radiusS
                  color: starHov.containsMouse?Qt.alpha(Color.mOnSurface,0.1):"transparent"; Behavior on color{ColorAnimation{duration:80}}
                  NIcon { anchors.centerIn: parent; icon: (root.widgetPinned[modelData.id]??true)?"star-filled":"star"; pointSize: Style.fontSizeM; applyUiScale: false; color: (root.widgetPinned[modelData.id]??true)?Color.mPrimary:Color.mOnSurfaceVariant; Behavior on color{ColorAnimation{duration:120}} }
                  MouseArea { id: starHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root._togglePin(modelData.id); onEntered: TooltipService.show(parent,(root.widgetPinned[modelData.id]??true)?"Unpin":"Pin to island"); onExited: TooltipService.hide() }
                }
                // Remove widget
                Rectangle {
                  width: Math.round(28*Style.uiScaleRatio); height: width; radius: Style.radiusS
                  color: trashHov.containsMouse?Qt.alpha(Color.mError,0.15):"transparent"; Behavior on color{ColorAnimation{duration:80}}
                  NIcon { anchors.centerIn: parent; icon: "trash"; pointSize: Style.fontSizeM; applyUiScale: false; color: trashHov.containsMouse?Color.mError:Color.mOnSurfaceVariant; Behavior on color{ColorAnimation{duration:80}} }
                  MouseArea { id: trashHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeWidget(modelData.id); onEntered: TooltipService.show(parent,"Remove widget"); onExited: TooltipService.hide() }
                }
              }
              MouseArea { id: wHov; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            }
          }

          // Downloadable widgets from sources
          Repeater {
            model: root.remoteWidgets
            delegate: Rectangle {
              required property var modelData; required property int index
              width: parent.width; height: Math.round(42*Style.uiScaleRatio)
              color: dlHov.containsMouse?Qt.alpha(Color.mOnSurface,0.06):"transparent"
              Behavior on color { ColorAnimation { duration: 80 } }
              RowLayout {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.marginM; rightMargin: Style.marginS } spacing: Style.marginS
                NIcon { icon: modelData.iconFallback || "puzzle"; pointSize: Style.fontSizeL; applyUiScale: false; color: Color.mOnSurfaceVariant; opacity: 0.7 }
                NText { Layout.fillWidth: true; text: modelData.name; pointSize: Style.fontSizeS; color: Color.mOnSurfaceVariant }
                NText { text: modelData.version || ""; pointSize: Style.fontSizeXXS; color: Color.mOnSurfaceVariant; opacity: 0.5 }
                // Download button
                Rectangle {
                  width: Math.round(28*Style.uiScaleRatio); height: width; radius: Style.radiusS
                  color: dlBtn.containsMouse?Qt.alpha(Color.mPrimary,0.18):"transparent"; Behavior on color{ColorAnimation{duration:80}}
                  NIcon { anchors.centerIn: parent; icon: "download"; pointSize: Style.fontSizeM; applyUiScale: false; color: dlBtn.containsMouse?Color.mPrimary:Color.mOnSurfaceVariant; Behavior on color{ColorAnimation{duration:80}} }
                  MouseArea { id: dlBtn; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.installWidget(modelData); onEntered: TooltipService.show(parent,"Install "+modelData.name); onExited: TooltipService.hide() }
                }
              }
              MouseArea { id: dlHov; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            }
          }

          // Empty state when no remote widgets and not fetching
          Rectangle {
            visible: root.widgetMenuOpen && root.remoteWidgets.length === 0 && !root.fetchingRegistry && root.widgetSources.length > 0
            width: parent.width; height: Math.round(36*Style.uiScaleRatio); color: "transparent"
            NText { anchors.centerIn: parent; text: "No new widgets available"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant; opacity: 0.6 }
          }
        }

        // Settings panel  -  widget sources + Steam path
        Rectangle { width: parent.width; height: 1; visible: root.settingsPanelOpen; color: Color.mOutline; opacity: 0.5 }
        Column {
          visible: root.settingsPanelOpen; width: parent.width; spacing: 0; padding: Style.marginS

          Repeater {
            model: root.widgetSources
            delegate: RowLayout {
              required property var modelData; required property int index
              width: parent.width - Style.marginS*2; spacing: Style.marginXS
              NIcon { icon: "source-code"; pointSize: Style.fontSizeM; applyUiScale: false; color: Color.mOnSurfaceVariant }
              ColumnLayout { Layout.fillWidth: true; spacing: 0
                NText { text: modelData.name; pointSize: Style.fontSizeS; color: Color.mOnSurface }
                NText { text: modelData.url; pointSize: Style.fontSizeXXS; color: Color.mOnSurfaceVariant; elide: Text.ElideRight; Layout.fillWidth: true }
              }
              Rectangle {
                width: Math.round(26*Style.uiScaleRatio); height: width; radius: Style.radiusS
                color: srcTrash.containsMouse?Qt.alpha(Color.mError,0.15):"transparent"; Behavior on color{ColorAnimation{duration:80}}
                NIcon { anchors.centerIn: parent; icon: "trash"; pointSize: Style.fontSizeS; applyUiScale: false; color: srcTrash.containsMouse?Color.mError:Color.mOnSurfaceVariant }
                MouseArea { id: srcTrash; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeWidgetSource(modelData.url) }
              }
            }
          }

          RowLayout {
            width: parent.width - Style.marginS*2; spacing: Style.marginXS
            ColumnLayout { Layout.fillWidth: true; spacing: Style.marginXXS
              TextField {
                id: srcNameField; Layout.fillWidth: true; placeholderText: "Source name"
                placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6)
                font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
                background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
              }
              TextField {
                id: srcUrlField; Layout.fillWidth: true; placeholderText: "https://github.com/user/repo"
                placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6)
                font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
                background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
              }
            }
            Rectangle {
              width: Math.round(30*Style.uiScaleRatio); height: width; radius: Style.radiusS
              color: addBtn.containsMouse?Qt.alpha(Color.mPrimary,0.18):"transparent"; Behavior on color{ColorAnimation{duration:80}}
              NIcon { anchors.centerIn: parent; icon: "plus"; pointSize: Style.fontSizeM; applyUiScale: false; color: addBtn.containsMouse?Color.mPrimary:Color.mOnSurfaceVariant }
              MouseArea { id: addBtn; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (srcNameField.text.trim() && srcUrlField.text.trim()) {
                    root.addWidgetSource(srcNameField.text, srcUrlField.text);
                    srcNameField.text = ""; srcUrlField.text = "";
                  }
                }
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; visible: root.settingsPanelOpen; color: Color.mOutline; opacity: 0.5 }
        Column {
          visible: root.settingsPanelOpen; width: parent.width; spacing: 0; padding: Style.marginS
          NText { text: "Steam library path"; pointSize: Style.fontSizeXS; font.weight: Style.fontWeightSemiBold; color: Color.mOnSurfaceVariant }
          Item { width: 1; height: Style.marginXXS }
          Row { spacing: Style.marginXS; width: parent.width - Style.marginS*2
            NIcon { icon: "brand-steam"; pointSize: Style.fontSizeM; applyUiScale: false; color: Color.mOnSurfaceVariant; anchors.verticalCenter: parent.verticalCenter }
            TextField {
              id: steamPathField; width: parent.width - Style.marginS*2 - Style.fontSizeM - Style.marginXS
              text: root.steamPath; placeholderText: "~/.local/share/Steam"
              placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6)
              font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
              background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
              onEditingFinished: {
                root.steamPath = text.trim() || "~/.local/share/Steam";
                root._saveState();
                root._recentGamesFetched = false;
                recentGamesProc.running = false;
                Qt.callLater(function(){ recentGamesProc.running = true; });
              }
            }
          }
        }

        // Shortcuts panel  -  toggled by "+" in shortcuts mode
        Rectangle { width: parent.width; height: 1; visible: root.shortcutsPanelOpen; color: Color.mOutline; opacity: 0.5 }
        Column {
          visible: root.shortcutsPanelOpen; width: parent.width; spacing: 0; padding: Style.marginS

          Repeater {
            model: root.customShortcuts
            delegate: RowLayout {
              required property var modelData; required property int index
              width: parent.width - Style.marginS*2; spacing: Style.marginXS
              NIcon { icon: modelData.icon || "terminal-2"; pointSize: Style.fontSizeM; applyUiScale: false; color: Color.mOnSurface }
              ColumnLayout { Layout.fillWidth: true; spacing: 0
                NText { text: modelData.name; pointSize: Style.fontSizeS; color: Color.mOnSurface }
                NText { text: modelData.command; pointSize: Style.fontSizeXXS; color: Color.mOnSurfaceVariant; elide: Text.ElideRight; Layout.fillWidth: true }
              }
              Rectangle {
                width: Math.round(26*Style.uiScaleRatio); height: width; radius: Style.radiusS
                color: scTrash.containsMouse?Qt.alpha(Color.mError,0.15):"transparent"; Behavior on color{ColorAnimation{duration:80}}
                NIcon { anchors.centerIn: parent; icon: "trash"; pointSize: Style.fontSizeS; applyUiScale: false; color: scTrash.containsMouse?Color.mError:Color.mOnSurfaceVariant }
                MouseArea { id: scTrash; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeShortcut(index) }
              }
            }
          }

          // App search + picker
          ColumnLayout { width: parent.width - Style.marginS*2; spacing: Style.marginXXS
            TextField {
              id: scSearchField; Layout.fillWidth: true; placeholderText: "Search apps..."
              placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6)
              font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
              background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
            }
            Flickable {
              Layout.fillWidth: true
              implicitHeight: Math.min(appCol.implicitHeight, Math.round(200*Style.uiScaleRatio))
              contentHeight: appCol.implicitHeight; clip: true
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              Column {
                id: appCol; width: parent.width; spacing: 0
                Repeater {
                  model: {
                    if (typeof DesktopEntries === 'undefined') return [];
                    var q = scSearchField.text.toLowerCase().trim();
                    var apps = DesktopEntries.applications.values || [];
                    var filtered = apps.filter(function(a) {
                      if (!a.name || a.noDisplay) return false;
                      return !q || (a.name||"").toLowerCase().indexOf(q) !== -1;
                    });
                    filtered.sort(function(a,b){ return (a.name||"").localeCompare(b.name||""); });
                    return filtered.slice(0, 50);
                  }
                  delegate: Rectangle {
                    required property var modelData
                    width: appCol.width; height: Math.round(38*Style.uiScaleRatio)
                    color: appHov.containsMouse ? Qt.alpha(Color.mPrimary, 0.1) : "transparent"
                    Behavior on color { ColorAnimation { duration: 80 } }
                    radius: Style.radiusS
                    RowLayout {
                      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.marginXS; rightMargin: Style.marginXS }
                      spacing: Style.marginS
                      IconImage {
                        width: Math.round(22*Style.uiScaleRatio); height: width
                        source: "image://icon/" + (modelData.icon || "application-x-executable")
                        smooth: true; asynchronous: true
                      }
                      NText { Layout.fillWidth: true; text: modelData.name || ""; pointSize: Style.fontSizeS; color: Color.mOnSurface; elide: Text.ElideRight }
                    }
                    MouseArea {
                      id: appHov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var appId = (modelData.id || "").replace(/\.desktop$/, "");
                        var iconSrc = modelData.icon ? ("image://icon/" + modelData.icon) : "app-window";
                        root.addShortcut(modelData.name, "gtk-launch " + appId, iconSrc, true);
                        scSearchField.text = "";
                        root.shortcutsPanelOpen = false;
                      }
                    }
                  }
                }
              }
            }
          }

          // Custom command form
          Rectangle { width: parent.width - Style.marginS*2; height: 1; color: Color.mOutline; opacity: 0.4 }
          RowLayout {
            width: parent.width - Style.marginS*2; spacing: Style.marginXS
            ColumnLayout { Layout.fillWidth: true; spacing: Style.marginXXS
              RowLayout { Layout.fillWidth: true; spacing: Style.marginXXS
                TextField {
                  id: scNameField; Layout.fillWidth: true; placeholderText: "Name"
                  placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6); font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
                  background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
                }
                TextField {
                  id: scIconField; implicitWidth: Math.round(90*Style.uiScaleRatio); placeholderText: "icon"
                  placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6); font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
                  background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
                }
              }
              TextField {
                id: scCmdField; Layout.fillWidth: true; placeholderText: "command or /path/to/app.desktop"
                placeholderTextColor: Qt.alpha(Color.mOnSurfaceVariant, 0.6); font.pointSize: Style.fontSizeXS; color: Color.mOnSurface
                background: Rectangle { color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusS }
                onAccepted: {
                  root._resolveDesktop(scCmdField.text, scNameField.text, scIconField.text, function(n, ic) {
                    root.addShortcut(n, scCmdField.text, ic);
                    scNameField.text=""; scCmdField.text=""; scIconField.text="";
                  });
                }
              }
            }
            Rectangle {
              width: Math.round(30*Style.uiScaleRatio); height: width; radius: Style.radiusS
              color: scAddBtn.containsMouse?Qt.alpha(Color.mPrimary,0.18):"transparent"; Behavior on color{ColorAnimation{duration:80}}
              NIcon { anchors.centerIn: parent; icon: "plus"; pointSize: Style.fontSizeM; applyUiScale: false; color: scAddBtn.containsMouse?Color.mPrimary:Color.mOnSurfaceVariant }
              MouseArea { id: scAddBtn; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root._resolveDesktop(scCmdField.text, scNameField.text, scIconField.text, function(n, ic) {
                    root.addShortcut(n, scCmdField.text, ic);
                    scNameField.text=""; scCmdField.text=""; scIconField.text="";
                  });
                }
              }
            }
          }
        }
      }
    }
  }


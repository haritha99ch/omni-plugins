import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
  id: root
  property var pluginApi: null

  property bool overlayActive: false
  property var  _overlayComponent: null
  property var  _windows: ({})  // screen.name -> OmniOverlayWindow
  property var  _activeWindow: null

  readonly property var _overlayWindow: _activeWindow

  onPluginApiChanged: {
    if (!pluginApi) return;
    _overlayComponent = Qt.createComponent("file://" + pluginApi.pluginDir + "/OmniOverlayWindow.qml");
    if (_overlayComponent.status === Component.Error)
      Logger.e("OmniOverlay", "pre-load error:", _overlayComponent.errorString());
  }

  IpcHandler {
    target: "plugin:omni-overlay"
    function toggle() {
      if (root.overlayActive) root.closeOmniOverlay();
      else root.openOmniOverlay();
    }
  }

  function _setActiveWindow(win) {
    for (var sn in root._windows) root._windows[sn].showVoiceHud = false;
    if (win) win.showVoiceHud = true;
    root._activeWindow = win;
  }

  function openOmniOverlay() {
    if (root.overlayActive) return;
    root.overlayActive = true;
    if (!pluginApi) return;
    pluginApi.withCurrentScreen(function(s) {
      if (root._activeWindow && root._activeWindow !== root._windows[s.name])
        root._activeWindow.panelsVisible = false;
      if (root._windows[s.name]) {
        _setActiveWindow(root._windows[s.name]);
        root._activeWindow.panelsVisible = true;
      } else {
        _launchOverlay(s);
      }
    });
  }

  function _launchOverlay(screen) {
    Logger.i("OmniOverlay", "_launchOverlay on screen:", screen?.name);
    if (!_overlayComponent) return;
    if (_overlayComponent.status === Component.Error) {
      Logger.e("OmniOverlay", "load error:", _overlayComponent.errorString()); return;
    }
    var win = _overlayComponent.createObject(null, { screen: screen, pluginApi: pluginApi });
    Logger.i("OmniOverlay", "window created:", win !== null, "screen:", screen?.name);
    if (!win) return;
    var wins = Object.assign({}, root._windows);
    wins[screen.name] = win;
    root._windows = wins;
    _setActiveWindow(win);
    win.positionSaved.connect(function(key, x, y) { _savePos(key, x, y); });
    if (!root.overlayActive) win.panelsVisible = false;
  }

  function closeOmniOverlay() {
    if (!root.overlayActive) return;
    root.overlayActive = false;
    if (root._activeWindow) root._activeWindow.panelsVisible = false;
  }

  function _savePos(key, x, y) {
    if (!pluginApi) return;
    var s = Object.assign({}, pluginApi.pluginSettings);
    s[key] = { x: x, y: y };
    pluginApi.pluginSettings = s;
    pluginApi.saveSettings();
  }
}

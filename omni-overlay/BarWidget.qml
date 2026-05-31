import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.Commons
import qs.Services.Compositor
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property ShellScreen screen
  property var pluginApi: null

  property string widgetId: ""
  property string section: ""
  property string configSection: section
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  property var widgetMetadata: BarWidgetRegistry.widgetMetadata[widgetId] ?? {}
  readonly property string screenName: screen ? screen.name : ""
  property var widgetSettings: Settings.getBarWidgetSettingsForScreen(screenName, configSection || section, sectionWidgetIndex)

  readonly property var mainInstance:    pluginApi?.mainInstance ?? null
  readonly property bool overlayActive:  mainInstance?.overlayActive ?? false
  readonly property var discordWidget:   mainInstance?._overlayWindow?.getWidget("discord") ?? null
  readonly property bool discordConnected: discordWidget?.discordConnected ?? false
  readonly property bool anySpeaking: {
    if (!discordWidget?.voiceParticipants) return false;
    return discordWidget.voiceParticipants.some(function(p){ return p.speaking; });
  }

  ListModel { id: overlayAppsModel }

  // Normalize access — Omni build uses ListModel (.count/.get), vanilla uses plain array (.length/[i])
  function _winCount() {
    var ws = CompositorService.windows;
    return (ws.count !== undefined) ? ws.count : (ws.length || 0);
  }
  function _winGet(i) {
    var ws = CompositorService.windows;
    return (ws.get !== undefined) ? ws.get(i) : ws[i];
  }

  function _refreshOverlayApps() {
    overlayAppsModel.clear();
    var n = _winCount();
    for (var i = 0; i < n; i++) {
      var w = _winGet(i);
      if (w && w.workspaceName === "special:overlay-apps" && w.title !== "overlay-placeholder")
        overlayAppsModel.append({ appId: w.appId || w.class || "", winTitle: w.title || "", winIndex: i });
    }
  }

  Connections {
    target: CompositorService.windows
    function onCountChanged() { root._refreshOverlayApps(); }
    function onLengthChanged() { root._refreshOverlayApps(); }
  }
  Component.onCompleted: _refreshOverlayApps()

  readonly property real _capsuleH: Style.getCapsuleHeightForScreen(screen?.name)
  readonly property real _iconSz: Math.round(_capsuleH * 0.55)

  implicitWidth: capsule.implicitWidth
  implicitHeight: _capsuleH

  // Single grouped capsule containing game button + overlay app buttons
  Rectangle {
    id: capsule
    anchors.centerIn: parent
    implicitWidth: inner.implicitWidth + Style.marginS * 2
    height: root._capsuleH
    radius: Style.radiusM
    color: Style.capsuleColor
    border.color: anySpeaking ? Qt.alpha(Color.mPrimary, 0.5)
                 : overlayActive ? Qt.alpha(Color.mPrimary, 0.5)
                 : Style.capsuleBorderColor
    border.width: Style.capsuleBorderWidth
    Behavior on border.color { ColorAnimation { duration: 150 } }

    RowLayout {
      id: inner
      anchors.centerIn: parent
      spacing: 0

      // Game controller icon
      Item {
        Layout.preferredWidth: root._capsuleH
        Layout.preferredHeight: root._capsuleH

        NIcon {
          anchors.centerIn: parent
          icon: "device-gamepad-2"
          pointSize: root._iconSz * 0.85
          applyUiScale: false
          color: overlayActive ? Color.mPrimary
               : anySpeaking  ? Color.mPrimary
               : Color.mOnSurface
          Behavior on color { ColorAnimation { duration: 120 } }
        }

        Rectangle {
          visible: discordConnected
          width: 6; height: 6; radius: 3
          color: anySpeaking ? Color.mPrimary : Color.mOnSurfaceVariant
          anchors.top: parent.top; anchors.right: parent.right
          anchors.topMargin: 4; anchors.rightMargin: 4
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (mainInstance) {
              if (overlayActive) mainInstance.closeOmniOverlay();
              else mainInstance.openOmniOverlay();
            }
          }
          onPressAndHold: PanelService.showContextMenu(ctxMenu, parent, screen)
        }

        NPopupContextMenu {
          id: ctxMenu
          model: [{ "label": I18n.tr("actions.widget-settings"), "action": "widget-settings", "icon": "settings" }]
          onTriggered: action => {
            ctxMenu.close(); PanelService.closeContextMenu(screen);
            if (action === "widget-settings")
              BarService.openWidgetSettings(screen, configSection || section, sectionWidgetIndex, widgetId, widgetSettings);
          }
        }
      }

      // Divider — only when there are overlay apps
      Rectangle {
        visible: overlayAppsModel.count > 0
        width: 1; height: Math.round(root._capsuleH * 0.55)
        color: Color.mOutline; opacity: 0.5
      }

      // Overlay app buttons
      Repeater {
        model: overlayAppsModel
        delegate: Item {
          required property var modelData
          Layout.preferredWidth: root._capsuleH
          Layout.preferredHeight: root._capsuleH

          IconImage {
            anchors.centerIn: parent
            width: root._iconSz; height: root._iconSz
            source: "image://icon/" + (modelData.appId || "application-x-executable")
            smooth: true; asynchronous: true
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: {
              var w = root._winGet(modelData.winIndex);
              if (w) CompositorService.focusWindow(w);
            }
            onEntered: TooltipService.show(parent, modelData.winTitle)
            onExited: TooltipService.hide()
          }
        }
      }
    }
  }
}

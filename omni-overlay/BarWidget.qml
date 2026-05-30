import QtQuick
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

NIconButton {
  id: root

  property ShellScreen screen
  property var pluginApi: null

  // Standard bar widget properties
  property string widgetId: ""
  property string section: ""
  property string configSection: section
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  property var widgetMetadata: BarWidgetRegistry.widgetMetadata[widgetId] ?? {}
  readonly property string screenName: screen ? screen.name : ""
  property var widgetSettings: Settings.getBarWidgetSettingsForScreen(screenName, configSection || section, sectionWidgetIndex)

  // Access state from Main.qml via mainInstance
  readonly property var mainInstance: pluginApi?.mainInstance ?? null
  readonly property bool overlayActive: mainInstance?.overlayActive ?? false
  readonly property var discordWidget: mainInstance?._overlayWindow?.getWidget("discord") ?? null
  readonly property bool discordConnected: discordWidget?.discordConnected ?? false
  readonly property bool anySpeaking: {
    if (!discordWidget?.voiceParticipants) return false;
    return discordWidget.voiceParticipants.some(function (p) { return p.speaking; });
  }

  icon: "device-gamepad-2"
  tooltipText: overlayActive ? "Close Omni Overlay" : "Open Omni Overlay (Super+G)"
  tooltipDirection: "bar"
  baseSize: Style.getCapsuleHeightForScreen(screen?.name)
  applyUiScale: false
  customRadius: Style.radiusL

  // Pulse primary color when someone is speaking in Discord voice
  colorBg: anySpeaking ? Qt.alpha(Color.mPrimary, 0.2) : Style.capsuleColor
  colorFg: overlayActive ? Color.mPrimary : Color.mOnSurface

  border.color: overlayActive ? Qt.alpha(Color.mPrimary, 0.5) : Style.capsuleBorderColor
  border.width: Style.capsuleBorderWidth

  // Small indicator dot when Discord is connected
  Rectangle {
    visible: discordConnected
    width: 6
    height: 6
    radius: 3
    color: anySpeaking ? Color.mPrimary : Color.mOnSurfaceVariant
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: 4
    anchors.rightMargin: 4
  }

  onClicked: {
    if (mainInstance) {
      if (overlayActive) mainInstance.closeOmniOverlay();
      else mainInstance.openOmniOverlay();
    }
  }

  NPopupContextMenu {
    id: contextMenu
    model: [
      {
        "label": I18n.tr("actions.widget-settings"),
        "action": "widget-settings",
        "icon": "settings"
      }
    ]
    onTriggered: action => {
                   contextMenu.close();
                   PanelService.closeContextMenu(screen);
                   if (action === "widget-settings") {
                     BarService.openWidgetSettings(screen, configSection || section, sectionWidgetIndex, widgetId, widgetSettings);
                   }
                 }
  }

  onRightClicked: {
    PanelService.showContextMenu(contextMenu, root, screen);
  }
}

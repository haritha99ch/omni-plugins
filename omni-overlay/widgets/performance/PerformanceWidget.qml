import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.System
import qs.Services.UI
import qs.Widgets

Item {
  id: root
  property var  pluginApi: null
  property bool panelsVisible: true
  property bool active: true  // set false to release SystemStatService

  readonly property real cardH: 90 * Style.uiScaleRatio
  readonly property string diskPath: {
    var w = BarService.lookupWidget("SystemMonitor");
    return (w && w.diskPath) ? w.diskPath : "/";
  }

  function _updateReg() {
    if (panelsVisible && active) SystemStatService.registerComponent("overlay-performance");
    else                         SystemStatService.unregisterComponent("overlay-performance");
  }
  onPanelsVisibleChanged: _updateReg()
  onActiveChanged: _updateReg()
  Component.onCompleted: _updateReg()
  Component.onDestruction: SystemStatService.unregisterComponent("overlay-performance")

  implicitWidth: 400
  implicitHeight: pRect.height
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    id: pRect
    width: 400
    height: pCol.implicitHeight + Style.marginL * 2
    color: Color.mSurface; border.color: Color.mOutline; border.width: 1; radius: Style.radiusL; clip: true

    ColumnLayout {
      id: pCol; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginL } spacing: Style.marginM
      RowLayout { Layout.fillWidth: true; spacing: Style.marginM
        NIcon { icon: "device-analytics"; pointSize: Style.fontSizeXXL; color: Color.mPrimary }
        NText { text: "System Performance"; pointSize: Style.fontSizeL; font.weight: Style.fontWeightBold; color: Color.mOnSurface; Layout.fillWidth: true }
      }
      NBox { Layout.fillWidth: true; Layout.preferredHeight: root.cardH
        ColumnLayout { anchors.fill: parent; anchors.margins: Style.marginS; anchors.bottomMargin: Style.radiusM*0.5; spacing: Style.marginXS
          RowLayout { Layout.fillWidth: true; spacing: Style.marginXS
            NIcon { icon: "cpu-usage"; pointSize: Style.fontSizeXS; color: Color.mPrimary }
            NText { text: `${Math.round(SystemStatService.cpuUsage)}% (${SystemStatService.cpuFreq.replace(/[^0-9.]/g,"")} GHz)`; pointSize: Style.fontSizeXS; color: Color.mPrimary; font.family: Settings.data.ui.fontFixed }
            NIcon { icon: "cpu-temperature"; pointSize: Style.fontSizeXS; color: Color.mSecondary }
            NText { text: `${Math.round(SystemStatService.cpuTemp)} degC`; pointSize: Style.fontSizeXS; color: Color.mSecondary; font.family: Settings.data.ui.fontFixed; Layout.rightMargin: Style.marginS }
            Item { Layout.fillWidth: true }
            NText { text: "CPU"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
          }
          NGraph { Layout.fillWidth: true; Layout.fillHeight: true; values: SystemStatService.cpuHistory; values2: SystemStatService.cpuTempHistory; minValue: 0; maxValue: 100; minValue2: Math.max(SystemStatService.cpuTempHistoryMin-5,0); maxValue2: Math.max(SystemStatService.cpuTempHistoryMax+5,1); color: Color.mPrimary; color2: Color.mSecondary; strokeWidth: Math.max(1,Style.uiScaleRatio); fill: true; fillOpacity: 0.15; updateInterval: SystemStatService.cpuUsageIntervalMs }
        }
      }
      NBox { Layout.fillWidth: true; Layout.preferredHeight: root.cardH
        ColumnLayout { anchors.fill: parent; anchors.margins: Style.marginS; anchors.bottomMargin: Style.radiusM*0.5; spacing: Style.marginXS
          RowLayout { Layout.fillWidth: true; spacing: Style.marginXS
            NIcon { icon: "memory"; pointSize: Style.fontSizeXS; color: Color.mPrimary }
            NText { text: `${Math.round(SystemStatService.memPercent)}% (${SystemStatService.memGb.toFixed(1)} GiB)`; pointSize: Style.fontSizeXS; color: Color.mPrimary; font.family: Settings.data.ui.fontFixed }
            Item { Layout.fillWidth: true }
            NText { text: "Memory"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
          }
          NGraph { Layout.fillWidth: true; Layout.fillHeight: true; values: SystemStatService.memHistory; minValue: 0; maxValue: 100; color: Color.mPrimary; strokeWidth: Math.max(1,Style.uiScaleRatio); fill: true; fillOpacity: 0.15; updateInterval: SystemStatService.memIntervalMs }
        }
      }
      NBox { Layout.fillWidth: true; Layout.preferredHeight: root.cardH
        ColumnLayout { anchors.fill: parent; anchors.margins: Style.marginS; anchors.bottomMargin: Style.radiusM*0.5; spacing: Style.marginXS
          RowLayout { Layout.fillWidth: true; spacing: Style.marginXS
            NIcon { icon: "download-speed"; pointSize: Style.fontSizeXS; color: Color.mPrimary }
            NText { text: SystemStatService.formatSpeed(SystemStatService.rxSpeed).replace(/([0-9.]+)([A-Za-z]+)/,"$1 $2")+"/s"; pointSize: Style.fontSizeXS; color: Color.mPrimary; font.family: Settings.data.ui.fontFixed; Layout.rightMargin: Style.marginS }
            NIcon { icon: "upload-speed"; pointSize: Style.fontSizeXS; color: Color.mSecondary }
            NText { text: SystemStatService.formatSpeed(SystemStatService.txSpeed).replace(/([0-9.]+)([A-Za-z]+)/,"$1 $2")+"/s"; pointSize: Style.fontSizeXS; color: Color.mSecondary; font.family: Settings.data.ui.fontFixed }
            Item { Layout.fillWidth: true }
            NText { text: "Network"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
          }
          NGraph { Layout.fillWidth: true; Layout.fillHeight: true; values: SystemStatService.rxSpeedHistory; values2: SystemStatService.txSpeedHistory; minValue: 0; maxValue: SystemStatService.rxMaxSpeed; minValue2: 0; maxValue2: SystemStatService.txMaxSpeed; color: Color.mPrimary; color2: Color.mSecondary; strokeWidth: Math.max(1,Style.uiScaleRatio); fill: true; fillOpacity: 0.15; updateInterval: SystemStatService.networkIntervalMs; animateScale: true }
        }
      }
      NBox { Layout.fillWidth: true; implicitHeight: detC.implicitHeight+Style.margin2M
        ColumnLayout { id: detC; anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.marginM } spacing: Style.marginXS
          RowLayout { Layout.fillWidth: true; spacing: Style.marginS; visible: SystemStatService.nproc>0
            NIcon { icon: "cpu-usage"; pointSize: Style.fontSizeM; color: Color.mPrimary } NText { text: "Load average:"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
            NText { text: `${SystemStatService.loadAvg1.toFixed(2)} | ${SystemStatService.loadAvg5.toFixed(2)} | ${SystemStatService.loadAvg15.toFixed(2)}`; pointSize: Style.fontSizeXS; color: Color.mOnSurface; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
          }
          RowLayout { Layout.fillWidth: true; spacing: Style.marginS; visible: SystemStatService.gpuAvailable
            NIcon { icon: "gpu-temperature"; pointSize: Style.fontSizeM; color: Color.mPrimary } NText { text: "GPU temp:"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
            NText { text: `${Math.round(SystemStatService.gpuTemp)} degC`; pointSize: Style.fontSizeXS; color: Color.mOnSurface; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
          }
          RowLayout { Layout.fillWidth: true; spacing: Style.marginS
            NIcon { icon: "storage"; pointSize: Style.fontSizeM; color: Color.mPrimary } NText { text: "Disk:"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
            NText { text: { var u=SystemStatService.diskUsedGb[root.diskPath]||0,s=SystemStatService.diskSizeGb[root.diskPath]||0,p=SystemStatService.diskPercents[root.diskPath]||0; return `${p}% (${u.toFixed(1)} / ${s.toFixed(1)} GB)`; } pointSize: Style.fontSizeXS; color: Color.mOnSurface; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; elide: Text.ElideMiddle }
          }
          RowLayout { Layout.fillWidth: true; spacing: Style.marginS; visible: SystemStatService.swapTotalGb>0
            NIcon { icon: "exchange"; pointSize: Style.fontSizeM; color: Color.mPrimary } NText { text: "Swap:"; pointSize: Style.fontSizeXS; color: Color.mOnSurfaceVariant }
            NText { text: `${SystemStatService.swapGb.toFixed(1)} / ${SystemStatService.swapTotalGb.toFixed(1)} GiB`; pointSize: Style.fontSizeXS; color: Color.mOnSurface; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
          }
        }
      }
    }
  }
}

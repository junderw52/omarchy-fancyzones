import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ZoneModel.js" as ZoneModel

// Zones plugin: the overlay shown while dragging a window (driven over the
// `zones` IPC target by hypr/zones.lua) and the zone editor (summoned with
// `omarchy-shell shell summon fancyzones '<payload>'`, bound to SUPER+SHIFT+Z).
Item {
  id: root

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/zones.json"

  // Drag overlay state.
  property bool dragging: false
  property string dragMonitor: ""
  property var dragZones: []
  property int dragActive: -1

  // Editor state. `opened` is what the shell checks for toggle().
  property bool opened: false
  property string monitor: ""
  property var area: ({ x: 0, y: 0, w: 0, h: 0 })
  property var columns: ZoneModel.defaultLayout()
  property int gap: 8
  property bool floatAll: false
  property var savedConfig: ({})

  readonly property var editorZones: ZoneModel.zones(root.columns, { x: 0, y: 0, w: root.area.w, h: root.area.h }, root.gap)
  readonly property real innerW: root.area.w - root.gap
  readonly property real innerH: root.area.h - root.gap

  function screenFor(name) {
    return Quickshell.screens.find(s => s.name === name) || Quickshell.screens[0]
  }

  function readConfig() {
    configFile.reload()
    try {
      var parsed = JSON.parse(configFile.text() || "{}")
      return parsed && typeof parsed === "object" ? parsed : {}
    } catch (e) {
      return {}
    }
  }

  function open(payloadJson) {
    var p = {}
    try { p = JSON.parse(payloadJson || "{}") } catch (e) {}
    var screen = root.screenFor(p.monitor || "")
    root.monitor = p.monitor || (screen ? screen.name : "")
    root.area = p.area || { x: 0, y: 0, w: screen ? screen.width : 0, h: screen ? screen.height : 0 }

    root.savedConfig = root.readConfig()
    var layouts = root.savedConfig.layouts || {}
    var layout = layouts[root.monitor] || layouts["default"]
    root.columns = ZoneModel.sanitize(layout && layout.columns)
    root.gap = root.savedConfig.gap !== undefined ? Number(root.savedConfig.gap) : 8
    root.floatAll = root.savedConfig.floatAll === true
    root.opened = true
  }

  function close() { root.opened = false }

  function save() {
    var cfg = JSON.parse(JSON.stringify(root.savedConfig || {}))
    cfg.version = 1
    cfg.gap = root.gap
    cfg.floatAll = root.floatAll
    cfg.layouts = cfg.layouts || {}
    cfg.layouts[root.monitor] = { columns: root.columns }
    if (!cfg.layouts["default"]) cfg.layouts["default"] = { columns: root.columns }
    configFile.setText(JSON.stringify(cfg, null, 2) + "\n")
    Quickshell.execDetached(["hyprctl", "eval", "Zones.reload()"])
    root.close()
  }

  FileView {
    id: configFile
    path: root.configPath
    blockLoading: true
    atomicWrites: true
    printErrors: false
  }

  IpcHandler {
    target: "zones"
    function show(payloadJson: string): string {
      try {
        var p = JSON.parse(payloadJson || "{}")
        root.dragMonitor = p.monitor || ""
        root.dragZones = p.zones || []
      } catch (e) {
        return "bad payload"
      }
      root.dragActive = -1
      root.dragging = true
      return "ok"
    }
    // `index` is 1-based to match the Lua side; 0 means no zone.
    function highlight(index: string): string {
      root.dragActive = parseInt(index) - 1
      return "ok"
    }
    function hide(): string { root.dragging = false; return "ok" }
    function edit(payloadJson: string): string { root.open(payloadJson); return "ok" }
    function ping(): string { return "ok" }
  }

  // Overlay while dragging a window. Visual-only: never takes clicks.
  PanelWindow {
    visible: root.dragging
    screen: root.screenFor(root.dragMonitor)
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "fancyzones"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    Repeater {
      model: root.dragZones

      Rectangle {
        required property var modelData
        required property int index
        readonly property bool hot: index === root.dragActive

        x: modelData.x
        y: modelData.y
        width: modelData.w
        height: modelData.h
        radius: Style.cornerRadius
        color: Util.alpha(Color.accent, hot ? 0.35 : 0.12)
        border.color: Util.alpha(Color.accent, hot ? 0.95 : 0.5)
        border.width: Math.max(2, Style.space(3))

        Behavior on color { ColorAnimation { duration: 90 } }

        Text {
          anchors.centerIn: parent
          text: index + 1
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          font.bold: true
          color: Util.alpha(Color.foreground, hot ? 0.9 : 0.4)
        }
      }
    }
  }

  // Zone editor.
  PanelWindow {
    id: editor
    visible: root.opened
    screen: root.screenFor(root.monitor)
    anchors { top: true; bottom: true; left: true; right: true }
    color: Util.alpha(Color.background, 0.85)
    WlrLayershell.namespace: "fancyzones-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Item {
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.save()
          event.accepted = true
        }
      }
    }

    // The usable area of the monitor (below the bar), where zones live.
    Item {
      id: canvas
      x: root.area.x
      y: root.area.y
      width: root.area.w
      height: root.area.h

      // Repeaters here use counts, not arrays: an array model is rebuilt on
      // every change to root.columns, which destroys the divider being dragged.
      Repeater {
        model: root.editorZones.length

        Rectangle {
          id: zone
          required property int index
          readonly property var modelData: root.editorZones[index] || ({ column: 0, row: 0, x: 0, y: 0, w: 0, h: 0 })
          readonly property var column: root.columns[modelData.column]
          readonly property bool canRemove: root.editorZones.length > 1

          x: modelData.x
          y: modelData.y
          width: modelData.w
          height: modelData.h
          radius: Style.cornerRadius
          color: Util.alpha(Color.accent, hover.hovered ? 0.22 : 0.12)
          border.color: Util.alpha(Color.accent, hover.hovered ? 0.95 : 0.55)
          border.width: Math.max(2, Style.space(3))

          HoverHandler { id: hover }

          Column {
            anchors.centerIn: parent
            spacing: Style.spacing.lg

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: zone.index + 1
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              color: Util.alpha(Color.foreground, 0.85)
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: Math.round(zone.column.width * 100) + "% × " + Math.round(zone.column.rows[zone.modelData.row] * 100) + "%"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              color: Util.alpha(Color.foreground, 0.6)
            }

            Column {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.spacing.sm
              opacity: hover.hovered ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 90 } }

              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Split side by side"
                bordered: true
                onClicked: root.columns = ZoneModel.splitVertical(root.columns, zone.modelData.column)
              }
              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Split top / bottom"
                bordered: true
                onClicked: root.columns = ZoneModel.splitHorizontal(root.columns, zone.modelData.column, zone.modelData.row)
              }
              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: zone.canRemove
                text: "Remove"
                bordered: true
                onClicked: root.columns = ZoneModel.remove(root.columns, zone.modelData.column, zone.modelData.row)
              }
            }
          }
        }
      }

      // Dividers between columns: drag to resize the columns on either side.
      Repeater {
        model: Math.max(0, root.columns.length - 1)

        Rectangle {
          id: columnDivider
          required property int index
          readonly property real modelData: ZoneModel.columnEdges(root.columns)[index] || 0

          width: Math.max(root.gap, Style.space(10))
          height: canvas.height - 2 * root.gap
          // Centered in the gap between the two columns.
          x: root.gap + modelData * root.innerW - root.gap / 2 - width / 2
          y: root.gap
          radius: width / 2
          color: Util.alpha(Color.accent, columnDrag.containsMouse || columnDrag.pressed ? 0.9 : 0)

          MouseArea {
            id: columnDrag
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.SplitHCursor
            function moveTo(mouse, snap) {
              var p = mapToItem(canvas, mouse.x, mouse.y)
              root.columns = ZoneModel.moveColumnEdge(root.columns, columnDivider.index, (p.x - root.gap) / root.innerW, snap)
            }
            onPositionChanged: function(mouse) { if (pressed) moveTo(mouse, false) }
            onReleased: function(mouse) { moveTo(mouse, true) }
          }
        }
      }

      // Dividers between rows inside each column.
      Repeater {
        model: root.columns.length

        Item {
          id: columnRows
          required property int index
          readonly property var modelData: root.columns[index] || ZoneModel.col(0)

          Repeater {
            model: Math.max(0, columnRows.modelData.rows.length - 1)

            Rectangle {
              id: rowDivider
              required property int index
              readonly property real modelData: ZoneModel.rowEdges(columnRows.modelData)[index] || 0

              readonly property real columnStart: columnRows.index === 0 ? 0 : ZoneModel.columnEdges(root.columns)[columnRows.index - 1]

              width: columnRows.modelData.width * root.innerW - root.gap
              height: Math.max(root.gap, Style.space(10))
              x: root.gap + columnStart * root.innerW
              y: root.gap + modelData * root.innerH - root.gap / 2 - height / 2
              radius: height / 2
              color: Util.alpha(Color.accent, rowDrag.containsMouse || rowDrag.pressed ? 0.9 : 0)

              MouseArea {
                id: rowDrag
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.SplitVCursor
                function moveTo(mouse, snap) {
                  var p = mapToItem(canvas, mouse.x, mouse.y)
                  root.columns = ZoneModel.moveRowEdge(root.columns, columnRows.index, rowDivider.index, (p.y - root.gap) / root.innerH, snap)
                }
                onPositionChanged: function(mouse) { if (pressed) moveTo(mouse, false) }
                onReleased: function(mouse) { moveTo(mouse, true) }
              }
            }
          }
        }
      }
    }

    // Toolbar.
    BorderSurface {
      id: toolbar
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(24)
      width: Math.min(parent.width - Style.space(32), toolbarContent.implicitWidth + 2 * Style.space(16) + toolbar.borderLeft + toolbar.borderRight)
      height: toolbarContent.implicitHeight + 2 * Style.space(16) + toolbar.borderTop + toolbar.borderBottom
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Column {
        id: toolbarContent
        anchors.centerIn: parent
        spacing: Style.spacing.lg

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.md

          Repeater {
            model: ZoneModel.presets

            Button {
              required property var modelData
              text: modelData.name
              tooltipText: modelData.description
              bordered: true
              onClicked: root.columns = ZoneModel.clone(modelData.columns)
            }
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(24)

          NumberField {
            anchors.verticalCenter: parent.verticalCenter
            label: "Gap"
            value: root.gap
            from: 0
            to: 64
            onModified: function(value) { root.gap = value }
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg

            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.floatAll
              onToggled: root.floatAll = !root.floatAll
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Open new windows floating"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              color: Color.foreground
            }
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: "Cancel"
            bordered: true
            onClicked: root.close()
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: "Save"
            bordered: true
            selected: true
            onClicked: root.save()
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Drag the lines between zones to resize · hover a zone to split or remove it · Enter saves · Esc cancels"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.foreground, 0.6)
        }
      }
    }
  }
}

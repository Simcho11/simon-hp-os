// Drop-zone hints shown for the whole of a window drag (niri gives no pointer
// position mid-drag, so zones can't light up under the cursor). Zones mirror
// lib/hittest.mjs: edges, corners, top-edge maximize and the top-centre picker.
import QtQuick

Item {
    id: hints

    required property var overlay
    readonly property var s: overlay.shell.settings
    readonly property int c: 48            // corner hint size
    readonly property int edge: 10         // drawn thickness of an edge zone
    readonly property bool off: overlay.dragCancelled || overlay.dragSuppressed

    opacity: off ? 0.35 : 1
    Behavior on opacity { NumberAnimation { duration: 120 * overlay.animMs } }

    component Zone: Rectangle {
        radius: 8
        color: Qt.rgba(hints.overlay.accent.r, hints.overlay.accent.g, hints.overlay.accent.b, 0.22)
        border.width: 2
        border.color: Qt.rgba(hints.overlay.accent.r, hints.overlay.accent.g, hints.overlay.accent.b, 0.7)
    }

    component Label: Rectangle {
        property alias text: label.text
        width: label.implicitWidth + 20
        height: 26
        radius: 13
        color: hints.overlay.surface
        border.width: 1
        border.color: Qt.rgba(hints.overlay.accent.r, hints.overlay.accent.g, hints.overlay.accent.b, 0.7)
        Text {
            id: label
            anchors.centerIn: parent
            color: hints.overlay.textColor
            font.pixelSize: 12
        }
    }

    // Left and right halves.
    Zone { visible: hints.s.edgeSnap; x: 0; y: hints.c; width: hints.edge; height: hints.height - 2 * hints.c }
    Zone { visible: hints.s.edgeSnap; x: hints.width - hints.edge; y: hints.c; width: hints.edge; height: hints.height - 2 * hints.c }
    Label { visible: hints.s.edgeSnap; text: "Left half"; x: hints.edge + 8; y: hints.height / 2 - height / 2 }
    Label { visible: hints.s.edgeSnap; text: "Right half"; x: hints.width - hints.edge - 8 - width; y: hints.height / 2 - height / 2 }

    // Corners: quarters.
    Repeater {
        model: hints.s.cornerSnap ? [[0, 0], [1, 0], [0, 1], [1, 1]] : []
        delegate: Zone {
            required property var modelData
            x: modelData[0] ? hints.width - hints.c : 0
            y: modelData[1] ? hints.height - hints.c : 0
            width: hints.c
            height: hints.c
            Text {
                anchors.centerIn: parent
                text: "¼"
                color: hints.overlay.textColor
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }
        }
    }

    // Top edge: maximize on the sides, layout picker in the centre.
    readonly property bool pickerTop: s.layoutPickerOnDrag
    Zone {
        visible: hints.s.topEdgeMaximize
        x: hints.c; y: 0; height: hints.edge
        width: (hints.pickerTop ? hints.width * 0.25 : hints.width - hints.c) - hints.c
    }
    Zone {
        visible: hints.s.topEdgeMaximize && hints.pickerTop
        x: hints.width * 0.75; y: 0; height: hints.edge
        width: hints.width * 0.25 - hints.c
    }
    Zone {
        visible: hints.pickerTop
        x: hints.width * 0.25 + 6; y: 0; height: hints.edge
        width: hints.width * 0.5 - 12
    }
    Label { visible: hints.s.topEdgeMaximize; text: "Maximize"; x: hints.c + 8; y: hints.edge + 8 }
    Label {
        visible: hints.pickerTop
        text: "Layouts"
        x: hints.width / 2 - width / 2; y: hints.edge + 8
    }

    // Status, kept clear of the dock.
    Label {
        anchors.horizontalCenter: parent.horizontalCenter
        y: hints.height - 140
        height: 34
        radius: 17
        text: hints.overlay.dragCancelled ? "Cancelled: the window will go back when you let go"
            : hints.overlay.dragSuppressed ? "Snapping off while Ctrl is held"
            : "Drop at an edge or corner to snap  ·  Esc cancels  ·  hold Ctrl to not snap"
    }
}

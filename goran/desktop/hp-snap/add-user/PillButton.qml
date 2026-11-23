// A button as HP-OS draws them: a pill, in the accent for the main action, otherwise a faint layer of the ink.
import QtQuick

Rectangle {
    id: button
    required property var look
    property string label: ""
    property bool primary: false
    property bool ready: true
    signal activated()
    implicitWidth: Math.max(140, caption.implicitWidth + 52)
    implicitHeight: 44
    radius: height / 2
    color: button.primary && button.ready ? button.look.accent
        : hit.pressed ? button.look.fillActive : hit.containsMouse && button.ready ? button.look.fillHover : button.look.fill
    scale: hit.pressed ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: 120 } }
    Accessible.role: Accessible.Button
    Accessible.name: button.label
    // The accent under the pointer: a little of its own ink over it.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        visible: button.primary && button.ready
        color: button.look.inkOnAccent
        opacity: hit.pressed ? 0.16 : hit.containsMouse ? 0.08 : 0
        Behavior on opacity { NumberAnimation { duration: 120 } }
    }
    Text {
        id: caption
        anchors.centerIn: parent
        text: button.label
        color: !button.ready ? button.look.tertiary : button.primary ? button.look.inkOnAccent : button.look.text
        font.family: button.look.font
        font.pixelSize: 15
        font.weight: button.primary ? Font.DemiBold : Font.Medium
    }
    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        enabled: button.ready
        cursorShape: Qt.PointingHandCursor
        onClicked: button.activated()
    }
}

import QtQuick

Item {
    id: activity
    implicitWidth: 108
    implicitHeight: 4
    property color ink: "#c8e1ff"
    property bool moving: true
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(activity.ink.r, activity.ink.g, activity.ink.b, 0.25)
    }
    Rectangle {
        id: light
        width: parent.width * 0.33
        height: parent.height
        radius: height / 2
        color: activity.ink
        property real phase: 0.5
        x: (parent.width - width) * phase
        SequentialAnimation on phase {
            running: activity.visible && activity.moving
            loops: Animation.Infinite
            NumberAnimation { from: 0; to: 1; duration: 720; easing.type: Easing.InOutSine }
            NumberAnimation { from: 1; to: 0; duration: 720; easing.type: Easing.InOutSine }
        }
    }
}

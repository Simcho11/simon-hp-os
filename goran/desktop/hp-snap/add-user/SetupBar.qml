// The progress bar for first-time setup. Setup reports in jumps and is silent while Nix evaluates,
// so between reports the bar keeps easing forward, without ever passing the next milestone.
import QtQuick

Item {
    id: bar
    property real progress: 0      // 0-100, as reported
    property real shown: 0
    Timer {
        interval: 400; running: true; repeat: true
        onTriggered: {
            const ceiling = bar.progress >= 100 ? 100 : bar.progress < 30 ? 29 : Math.min(99, bar.progress + 6)
            bar.shown = Math.max(bar.shown, bar.progress, bar.shown + Math.max(0, ceiling - bar.shown) * 0.015)
        }
    }
    Rectangle { anchors.fill: parent; radius: height / 2; color: Qt.rgba(1, 1, 1, 0.24) }
    Rectangle {
        height: parent.height
        radius: height / 2
        color: "white"
        width: Math.max(height, parent.width * Math.min(100, bar.shown) / 100)
        Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
    }
}

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "."

ShellRoot {
    id: arrival
    property bool releasing: false
    property bool slow: false
    property int fadeMs: 500
    // Height of the login screen's password field, as a share of the screen (LoginLens.qml).
    readonly property real lightPlace: 0.8
    readonly property int hour: new Date().getHours()
    readonly property bool daytime: hour >= 7 && hour < 19
    readonly property string picture: "file:///opt/hp-os/login/themes/hpos/hp-os-"
        + (daytime ? "daybreak" : "harmony-night") + ".jpg"

    function reveal(instant) {
        if (releasing) return
        if (instant) fadeMs = 0
        releasing = true
        finish.start()
    }
    Process {
        id: probe
        command: ["qs", "ipc", "-p", Quickshell.env("HP_OS_RUNTIME"), "call", "startupDesktop", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const state = text.trim()
                if (state === "skip" || state === "ready-instant") arrival.reveal(true)
                else if (state === "ready" && !settle.running) settle.start()
            }
        }
    }
    Timer {
        interval: 250; running: !arrival.releasing; repeat: true; triggeredOnStart: true
        onTriggered: if (!probe.running) probe.running = true
    }
    Timer { id: settle; interval: 100; onTriggered: arrival.reveal(false) }
    Timer { interval: 15000; running: !arrival.releasing; onTriggered: arrival.slow = true }
    Timer { id: finish; interval: arrival.fadeMs + 60; onTriggered: Qt.quit() }
    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { left: true; right: true; top: true; bottom: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "hp-os-desktop-arrival"
            color: "transparent"
            id: cover
            // Rises out of the black of the login handoff once the picture is decoded.
            property bool risen: false
            Timer { interval: 900; running: true; onTriggered: cover.risen = true }
            Rectangle {
                anchors.fill: parent
                color: "black"
                opacity: arrival.releasing ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: arrival.fadeMs; easing.type: Easing.InOutCubic } }
                Item {
                    anchors.fill: parent
                    opacity: cover.risen ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                    Image {
                        anchors.fill: parent
                        source: arrival.picture
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: width
                        sourceSize.height: height
                        onStatusChanged: if (status === Image.Ready || status === Image.Error) cover.risen = true
                    }
                    // A plain dim, like the login screen and setup: no colour of its own.
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.33) }
                    // Only the moving light normally; words appear only if startup takes unusually long.
                    Text {
                        visible: arrival.slow
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: light.y - height - 16
                        text: qsTr("Your desktop is still loading")
                        color: "white"; font.pixelSize: 20; font.weight: Font.Medium
                    }
                }
                // Lit from the first frame, in the place the password was on the login screen.
                LoginActivity {
                    id: light
                    ink: "white"
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Math.round(parent.height * arrival.lightPlace - height / 2)
                    width: Math.round(parent.height * 150 / 1080)
                    height: Math.max(3, Math.round(parent.height * 4 / 1080))
                }
                Button {
                    visible: arrival.slow
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: light.bottom
                    anchors.topMargin: 16
                    text: qsTr("Show desktop now")
                    onClicked: arrival.reveal(false)
                }
            }
        }
    }
}

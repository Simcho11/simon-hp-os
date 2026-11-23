// Shown at sign-in while an account's desktop is set up for the first time: the HP logo and a bar.
import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
    id: root
    readonly property bool preview: Quickshell.env("HP_OS_ADD_USER_PREVIEW") === "1"
    property real progress: 0
    // The setup ended without finishing. The bar stops where it was and says so; then the sign-in carries on (the
    // desktop this account already has, or the login screen, which says why), and the next sign-in tries again.
    property bool failed: Quickshell.env("HP_OS_FIRST_SETUP_PREVIEW") === "failed"

    Process {
        running: !root.preview
        command: ["/nix/var/nix/profiles/hp-os-accounts/bin/hp-os-account-setup"]
        stdout: SplitParser {
            onRead: line => {
                const found = /^HP-OS-PROGRESS (\d{1,3})$/.exec(line)
                if (found) root.progress = Math.min(100, Number(found[1]))
            }
        }
        onExited: (exitCode, exitStatus) => {
            // exitStatus 0 is QProcess's NormalExit (1, a crash, leaves no meaningful code).
            if (exitCode === 0 && exitStatus === 0) { root.progress = 100; leave.start() }
            else { root.failed = true; leaveAfterFailure.start() }
        }
    }
    Timer { id: leave; interval: 700; onTriggered: Qt.quit() }
    // Long enough to read; the preview (HP_OS_FIRST_SETUP_PREVIEW=failed) shows it the same way.
    Timer { id: leaveAfterFailure; interval: 5000; onTriggered: Qt.quit() }
    Component.onCompleted: if (root.preview && root.failed) leaveAfterFailure.start()
    Timer {
        interval: 300; repeat: true; running: root.preview && !root.failed && root.progress < 100
        onTriggered: { root.progress = Math.min(100, root.progress + 7); if (root.progress >= 100) leave.start() }
    }

    FloatingWindow {
        id: win
        visible: true
        title: "HP-OS"
        color: "black"
        implicitWidth: 1440
        implicitHeight: 900
        readonly property real d: Math.max(0.75, Math.min(2.2, Math.min(height / 1000, width / 1500)))
        Image {
            id: logo
            source: "file:///opt/hp-os/login/themes/hpos/hp-logo.png"
            width: Math.round(112 * win.d); height: width
            sourceSize: Qt.size(width * 2, height * 2)
            x: Math.round((parent.width - width) / 2)
            y: Math.round(parent.height * 0.5 - height * 0.82)
            smooth: true; mipmap: true
        }
        SetupBar {
            visible: !root.failed
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: logo.bottom
            anchors.topMargin: Math.round(58 * win.d)
            width: Math.round(280 * win.d); height: Math.max(3, Math.round(5 * win.d))
            progress: root.progress
        }
        Column {
            visible: root.failed
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: logo.bottom
            anchors.topMargin: Math.round(44 * win.d)
            width: Math.round(560 * win.d)
            spacing: Math.round(10 * win.d)
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: "white"
                font.family: "HarmonyOS Sans"
                font.pixelSize: Math.round(22 * win.d)
                font.weight: Font.DemiBold
                text: "Your desktop couldn’t be set up this time."
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: Qt.rgba(1, 1, 1, 0.72)
                font.family: "HarmonyOS Sans"
                font.pixelSize: Math.round(16 * win.d)
                text: "HP-OS tries again the next time you sign in."
            }
        }
    }
}

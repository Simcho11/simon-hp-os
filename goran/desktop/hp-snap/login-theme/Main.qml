// iNiR SDDM: picks the look theme.conf names. sync-pixel-sddm.py writes it from lock.loginScreen (Classic or
// iRiS) and lock.loginStyle (iRiS's Cover, Frame or Lens), so switching needs no root: this directory
// belongs to the user who installed it.
import QtQuick 2.15

Item {
    id: main
    // HP-OS: a device that has never been set up opens first-time setup instead of asking anyone to sign in.
    // The mark is a tiny QML file so this screen can see it without any privileges.
    Loader { id: firstBootMark; source: String(config.firstBootMark || "file:///var/lib/hp-os/first-boot.qml") }
    readonly property bool firstBoot: firstBootMark.status === Loader.Ready
    function openFirstSetup() {
        const login = styleLoader.item
        if (login && login.awaitingNewAccount !== undefined) login.awaitingNewAccount = true
        Qt.openUrlExternally("hpos-add-user:first-boot")
    }
    Timer { running: main.firstBoot && styleLoader.status === Loader.Ready; interval: 300; onTriggered: main.openFirstSetup() }
    readonly property var irisStyles: ({ cover: "LoginCover.qml", frame: "LoginFrame.qml", lens: "LoginLens.qml" })
    // HP-OS: the HP mark and the wordmark, top left, sized from the screen like the rest of the layout.
    Row {
        // Fades with the rest of the screen while signing in (LoginSurface).
        opacity: styleLoader.item && styleLoader.item.core && styleLoader.item.core.signingIn ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.InOutQuad } }
        readonly property real d: Math.max(0.75, Math.min(parent.width / 1440, parent.height / 900))
        anchors { top: parent.top; left: parent.left; topMargin: Math.round(30 * d); leftMargin: Math.round(36 * d) }
        z: 10
        spacing: Math.round(12 * d)
        Image {
            source: "hp-logo.png"
            width: Math.round(30 * parent.d); height: width
            sourceSize: Qt.size(width * 2, height * 2)
            anchors.verticalCenter: parent.verticalCenter
            smooth: true; mipmap: true
        }
        Text {
            text: "HP-OS"
            color: "white"
            anchors.verticalCenter: parent.verticalCenter
            font.family: String(config.irisFontMain || "HarmonyOS Sans")
            font.pixelSize: Math.round(20 * parent.d)
            font.weight: Font.Medium
            font.letterSpacing: Math.round(1.5 * parent.d)
        }
    }
    Loader {
        id: styleLoader
        anchors.fill: parent
        focus: true
        source: String(config.appearance || "classic") !== "iris" ? "ClassicLogin.qml"
            : parent.irisStyles[String(config.irisLoginStyle || "lens")] || "LoginLens.qml"
        // A login screen that fails to load locks people out: fall back to the Classic one.
        onStatusChanged: if (status === Loader.Error && String(source).indexOf("ClassicLogin.qml") < 0) source = "ClassicLogin.qml"
    }
    // Behind first-time setup, and the way back into it if it is ever closed. Gone once the account exists.
    Rectangle {
        anchors.fill: parent
        z: 20
        visible: main.firstBoot && !(styleLoader.item && styleLoader.item.core && String(styleLoader.item.core.addedLogin || "").length > 0)
        color: "#071a3f"
        MouseArea { anchors.fill: parent; hoverEnabled: true }
        Rectangle {
            anchors.centerIn: parent
            width: Math.round(parent.width * 0.17); height: Math.round(width * 0.24)
            radius: height / 2
            color: "white"
            Text {
                anchors.centerIn: parent
                text: "Set up this device"
                color: "#0b2a6b"
                font.family: String(config.irisFontMain || "HarmonyOS Sans")
                font.pixelSize: Math.round(parent.height * 0.32)
                font.weight: Font.DemiBold
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: main.openFirstSetup() }
        }
    }
}

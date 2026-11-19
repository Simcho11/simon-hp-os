// HP-OS welcome: at a person's first sign-in, on their own desktop. A glass pill says "Welcome to HP-OS", then grows
// into a window with the User Guide and four first moves. Light or dark, like the desktop around it. It also opens
// from Settings › Welcome. Nothing runs once it's closed.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "."

ShellRoot {
    id: app
    readonly property string home: Quickshell.env("HOME")
    readonly property string guide: app.home + "/.local/share/hp-os/HP-OS User Guide.pdf"
    // For trying it out: HP_OS_WELCOME_MODE=light|dark, HP_OS_WELCOME_NAME=Alex.
    property string mode: Quickshell.env("HP_OS_WELCOME_MODE") || "light"
    readonly property bool dark: app.mode === "dark"
    property string firstName: Quickshell.env("HP_OS_WELCOME_NAME") || ""
    property string wallpaper: ""
    readonly property var expressive: [0.16, 1, 0.3, 1, 1, 1]
    readonly property var through: [0.65, 0, 0.15, 1, 1, 1]

    // ── What the desktop looks like now: light or dark, its wallpaper, and the person's first name ──
    Process {
        id: look
        running: true
        command: ["/usr/bin/python3", "-I", "-c", `
import json, os, pwd, sys
home = os.path.expanduser("~")
state = os.environ.get("XDG_STATE_HOME", home + "/.local/state")
config = os.environ.get("XDG_CONFIG_HOME", home + "/.config")
try:
    mode = open(state + "/hp-os/appearance-mode").read().strip()
except OSError:
    mode = "light"
try:
    path = json.load(open(config + "/hp-os/config.json")).get("background", {}).get("wallpaperPath", "")
except (OSError, ValueError, AttributeError):
    path = ""
if not (isinstance(path, str) and os.path.isfile(path) and path.lower().endswith((".png", ".jpg", ".jpeg", ".webp"))):
    path = home + "/Pictures/Wallpapers/HP-OS/hp-os-" + ("harmony-night" if mode == "dark" else "daybreak") + ".png"
gecos = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
print(json.dumps({"mode": mode, "wallpaper": path, "name": (gecos or pwd.getpwuid(os.getuid()).pw_name).split()[0]}))
`]
        stdout: StdioCollector {
            onStreamFinished: {
                let found = {}
                try { found = JSON.parse(this.text) } catch (error) {}
                if (!Quickshell.env("HP_OS_WELCOME_MODE") && found.mode) app.mode = found.mode
                if (!app.firstName && found.name) app.firstName = found.name
                app.wallpaper = found.wallpaper ? "file://" + found.wallpaper : ""
                app.stage = 1
            }
        }
    }

    // 0 waiting · 1 the pill and its words · 2 grown into the window · 3 leaving
    property int stage: 0
    Timer { running: app.stage === 1; interval: 2300; onTriggered: app.stage = 2 }
    // The contents come in once the glass has mostly grown.
    property bool contentsShown: false
    Timer { running: app.stage === 2 && !app.contentsShown; interval: 750; onTriggered: app.contentsShown = true }
    function openGuide() {
        Qt.openUrlExternally("file://" + encodeURI(app.guide))
        app.leave()
    }
    function leave() {
        if (app.stage === 3) return
        app.stage = 3
        quitLater.start()
    }
    Timer { id: quitLater; interval: 420; onTriggered: Qt.quit() }

    FontLoader { source: "file:///opt/hp-os/login/themes/hpos/fonts/HarmonyOS_Sans.ttf" }
    FontLoader { id: symbols; source: "file:///opt/hp-os/login/themes/hpos/fonts/MaterialSymbolsRounded.ttf" }

    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "hp-os-welcome"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        readonly property real d: Math.max(0.7, Math.min(height / 1200, width / 1920) * 1.0)
        function px(n) { return Math.round(n * d) }
        readonly property color ink: app.dark ? "white" : "#0b2a6b"
        readonly property color soft: app.dark ? Qt.rgba(1, 1, 1, 0.74) : Qt.rgba(0.04, 0.16, 0.42, 0.7)

        component Label: Text {
            color: win.ink
            font.family: "HarmonyOS Sans"
            renderType: Text.NativeRendering
            wrapMode: Text.WordWrap
        }
        component Glyph: Text {
            font.family: symbols.name
            font.pixelSize: win.px(22)
            color: "white"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        component Pill: Rectangle {
            id: pill
            property string label: ""
            property bool strong: true
            property color fill: "white"
            property color text: "#0b2a6b"
            signal activated()
            implicitWidth: pillLabel.implicitWidth + win.px(56)
            height: win.px(50)
            radius: height / 2
            color: pillHit.pressed ? Qt.darker(pill.fill, 1.08) : pill.fill
            scale: pillHit.pressed ? 0.97 : 1
            Behavior on scale { NumberAnimation { duration: 120 } }
            Label { id: pillLabel; anchors.centerIn: parent; text: pill.label; color: pill.text; font.pixelSize: win.px(17); font.weight: Font.DemiBold }
            MouseArea { id: pillHit; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: pill.activated() }
        }

        // The desktop shows through, softened a little, so the window reads as in front.
        Rectangle {
            anchors.fill: parent
            color: app.dark ? Qt.rgba(0.02, 0.04, 0.1, 1) : Qt.rgba(0.88, 0.93, 0.99, 1)
            opacity: app.stage === 1 || app.stage === 2 ? (app.dark ? 0.32 : 0.3) : 0
            Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
            MouseArea { anchors.fill: parent }          // The desktop waits until the welcome is closed.
        }

        // What the glass bends: the person's wallpaper, softened like HP-OS's thick glass.
        Item {
            id: wallpaperLayer
            anchors.fill: parent
            visible: false
            Image { id: wallpaperImage; anchors.fill: parent; source: app.wallpaper; fillMode: Image.PreserveAspectCrop; asynchronous: true
                    sourceSize: Qt.size(win.width, win.height) }
        }
        Item {
            id: frostLayer
            anchors.fill: parent
            visible: false
            MultiEffect { anchors.fill: parent; source: wallpaperLayer; blurEnabled: true; blur: 1; blurMax: 48; saturation: 0.15 }
        }
        ShaderEffectSource { id: backdropTexture; anchors.fill: parent; sourceItem: frostLayer; live: true; visible: false }

        // ── The glass: a pill that greets, then grows into the window ──
        Item {
            id: card
            readonly property bool grown: app.stage >= 2
            width: card.grown ? win.px(980) : win.px(560)
            height: card.grown ? win.px(664) : win.px(132)
            x: Math.round((win.width - card.width) / 2)
            y: Math.round(win.height * 0.47 - card.height / 2)
            opacity: app.stage === 1 || app.stage === 2 ? 1 : 0
            scale: app.stage === 1 || app.stage === 2 ? 1 : 0.92
            Behavior on width { NumberAnimation { duration: 1050; easing.type: Easing.BezierSpline; easing.bezierCurve: app.through } }
            Behavior on height { NumberAnimation { duration: 1050; easing.type: Easing.BezierSpline; easing.bezierCurve: app.through } }
            Behavior on opacity { NumberAnimation { duration: app.stage === 3 ? 380 : 800; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: app.stage === 3 ? 380 : 900; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }

            GlassShape {
                id: pane
                anchors.fill: parent
                radius: card.grown ? win.px(36) : card.height / 2
                Behavior on radius { NumberAnimation { duration: 1050; easing.type: Easing.BezierSpline; easing.bezierCurve: app.through } }
                d: win.d
                frost: 1
                backdropItem: backdropTexture
                hostItem: win.contentItem
            }
            // Frosted white in light mode, smoky in dark, so the words read over any wallpaper.
            Rectangle {
                anchors.fill: parent
                radius: pane.radius
                color: app.dark ? Qt.rgba(0.09, 0.12, 0.19, 0.62) : Qt.rgba(1, 1, 1, 0.58)
                border.width: 1
                border.color: app.dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.75)
            }
            // A glint of light crossing the glass as it grows.
            Item {
                anchors.fill: parent
                clip: true
                Rectangle {
                    id: glint
                    width: parent.width * 0.35; height: parent.height * 2.2
                    y: -parent.height * 0.6
                    rotation: 18
                    x: card.grown ? parent.width * 1.4 : -parent.width * 0.6
                    Behavior on x { NumberAnimation { duration: 1300; easing.type: Easing.InOutQuad } }
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 0.5; color: app.dark ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.6) }
                        GradientStop { position: 1; color: "transparent" }
                    }
                }
            }

            // The greeting: one word at a time in the pill, then up into the window's header.
            Row {
                id: hello
                anchors.horizontalCenter: parent.horizontalCenter
                y: card.grown ? win.px(40) : Math.round((card.height - height) / 2)
                spacing: win.px(card.grown ? 9 : 13)
                Behavior on y { NumberAnimation { duration: 1050; easing.type: Easing.BezierSpline; easing.bezierCurve: app.through } }
                Repeater {
                    model: ["Welcome", "to", "HP-OS"]
                    Label {
                        id: word
                        required property string modelData
                        required property int index
                        text: modelData
                        wrapMode: Text.NoWrap
                        font.pixelSize: win.px(card.grown ? 32 : 46); font.weight: Font.DemiBold
                        Behavior on font.pixelSize { NumberAnimation { duration: 1050; easing.type: Easing.BezierSpline; easing.bezierCurve: app.through } }
                        color: word.index === 2 ? (app.dark ? "#9fd6ff" : "#1f6fe0") : win.ink
                        readonly property bool shown: app.stage >= 1 && wordClock.ticks > word.index
                        opacity: word.shown ? 1 : 0
                        transform: Translate { y: word.shown ? 0 : win.px(12); Behavior on y { NumberAnimation { duration: 700; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } } }
                        Behavior on opacity { NumberAnimation { duration: 600 } }
                    }
                }
            }
            Timer { id: wordClock; property int ticks: 0; running: app.stage >= 1 && ticks < 3; interval: wordClock.ticks === 0 ? 450 : 220; repeat: true; onTriggered: ticks++ }

            // ── The window's contents, once grown ──
            Column {
                id: body
                x: win.px(44); y: win.px(96)
                width: card.width - win.px(88)
                spacing: win.px(20)
                opacity: app.contentsShown && app.stage === 2 ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    color: win.soft
                    font.pixelSize: win.px(17)
                    text: (app.firstName ? "Hi " + app.firstName + ", you’re all set. " : "You’re all set. ") + "Here’s everything you need to find your way around."
                }
                // The User Guide: the window's main thing.
                Rectangle {
                    width: parent.width
                    height: guideRow.implicitHeight + win.px(48)
                    radius: win.px(26)
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: app.dark ? "#286ee6" : "#0b2a6b" }
                        GradientStop { position: 1; color: app.dark ? "#1446aa" : "#1750b4" }
                    }
                    Row {
                        id: guideRow
                        x: win.px(26); anchors.verticalCenter: parent.verticalCenter
                        spacing: win.px(26)
                        Rectangle {
                            width: win.px(88); height: win.px(112)
                            radius: win.px(12)
                            color: "white"
                            Column {
                                x: win.px(16); y: win.px(18); spacing: win.px(6)
                                Repeater { model: [0.55, 0.35, 0.22]; Rectangle { required property real modelData; width: win.px(40); height: win.px(4); radius: 2; color: Qt.rgba(0.04, 0.16, 0.42, modelData) } }
                            }
                            Label { x: win.px(16); anchors.bottom: parent.bottom; anchors.bottomMargin: win.px(14); text: "HP-OS"; color: "#0b2a6b"; font.pixelSize: win.px(13); font.weight: Font.Bold }
                        }
                        Column {
                            width: body.width - win.px(88) - win.px(26) * 3
                            spacing: win.px(6)
                            Label { text: "The HP-OS User Guide"; color: "white"; font.pixelSize: win.px(24); font.weight: Font.DemiBold }
                            Label {
                                width: parent.width
                                color: Qt.rgba(1, 1, 1, 0.82)
                                font.pixelSize: win.px(16.5)
                                lineHeight: 1.1
                                text: "Every gesture, shortcut and setting, with pictures. It’s also on your desktop, and in Settings whenever you need it."
                            }
                            Item { width: 1; height: win.px(8) }
                            Pill { label: "Open the User Guide"; onActivated: app.openGuide() }
                        }
                    }
                }
                // Four first moves.
                Row {
                    width: parent.width
                    spacing: win.px(14)
                    Repeater {
                        model: [
                            { glyph: "apps", tint: "#2f7cf6", title: "Open apps", text: "Click the grid in the Dock, or press Super+Space and type." },
                            { glyph: "search", tint: "#8a5cf6", title: "Search anything", text: "Apps, files, settings and quick sums: Super+S." },
                            { glyph: "splitscreen_left", tint: "#16a37f", title: "Snap windows", text: "Drag a window to an edge or corner to fill half or a quarter." },
                            { glyph: "tune", tint: "#f08a24", title: "Quick settings", text: "Wi-Fi, sound, brightness and dark mode, at the bottom right." }
                        ]
                        Rectangle {
                            id: tip
                            required property var modelData
                            width: (body.width - win.px(14) * 3) / 4
                            height: win.px(168)
                            radius: win.px(22)
                            color: app.dark ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.55)
                            border.width: 1
                            border.color: app.dark ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.85)
                            Column {
                                x: win.px(18); y: win.px(18)
                                width: tip.width - win.px(36)
                                spacing: win.px(6)
                                Rectangle {
                                    width: win.px(40); height: width; radius: win.px(12); color: tip.modelData.tint
                                    Glyph { anchors.centerIn: parent; text: tip.modelData.glyph }
                                }
                                Item { width: 1; height: win.px(4) }
                                Label { text: tip.modelData.title; font.pixelSize: win.px(16.5); font.weight: Font.DemiBold }
                                Label { width: parent.width; text: tip.modelData.text; color: win.soft; font.pixelSize: win.px(14) }
                            }
                        }
                    }
                }
                Item {
                    width: parent.width
                    height: win.px(54)
                    Label { anchors.verticalCenter: parent.verticalCenter; text: "You can find this again in Settings › Welcome."; color: win.soft; font.pixelSize: win.px(14.5) }
                    Pill {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        label: "Get started"
                        fill: app.dark ? "white" : "#0b2a6b"
                        text: app.dark ? "#0b2a6b" : "white"
                        onActivated: app.leave()
                    }
                }
            }
        }

        Shortcut { sequences: ["Return", "Enter", "Escape"]; enabled: app.stage === 2; onActivated: app.leave() }
    }
}

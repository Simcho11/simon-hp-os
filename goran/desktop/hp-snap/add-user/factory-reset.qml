// HP-OS Factory reset, opened from Settings > General. An administrator types their password twice; the device
// then restarts, erases every account and its files before anyone can sign in, and opens first-time setup.
import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
    id: app
    readonly property bool preview: Quickshell.env("HP_OS_RESET_PREVIEW") === "1"
    readonly property string previewRole: Quickshell.env("HP_OS_RESET_ROLE")
    property int step: 0                 // 0 what happens, 1 passwords, 2 restarting
    property bool checked: false
    property bool admin: false
    property bool busy: false
    property string notice: ""

    Process {
        id: request
        property string message: ""
        property var answer: null
        stdinEnabled: true
        command: ["/usr/bin/python3", "-I", Quickshell.shellPath("device-client.py"), "/run/hp-os/factory-reset.sock"]
        stdout: SplitParser { onRead: line => { try { request.answer = JSON.parse(line) } catch (error) {} } }
        onStarted: { request.write(request.message + "\n"); request.message = "" }
        onExited: app.answered(request.answer)
    }
    function ask(message) {
        request.answer = null
        request.message = JSON.stringify(message)
        request.running = true
    }
    function answered(answer) {
        app.busy = false
        if (!app.checked) {
            app.checked = true
            app.admin = !!answer && answer.admin === true
            return
        }
        if (answer && answer.ok) { app.step = 2; return }
        app.notice = answer && answer.error ? answer.error : "The reset couldn’t start. Nothing was changed."
        first.input.forceActiveFocus()
    }
    function erase() {
        if (!form.ready || app.busy) return
        app.busy = true
        app.notice = ""
        const password = first.text, again = second.text
        first.text = ""; second.text = ""
        if (app.preview) { mock.wrong = password === "wrong"; mock.start(); return }
        app.ask({ action: "erase", password: password, again: again })
    }
    Timer {
        id: mock; interval: 700; property bool wrong: false
        onTriggered: app.answered(wrong ? { ok: false, error: "That password isn’t correct." } : { ok: true })
    }
    Component.onCompleted: {
        if (app.preview) { app.checked = true; app.admin = app.previewRole !== "standard"; return }
        app.ask({ action: "check" })
    }

    FloatingWindow {
        id: win
        visible: true
        title: "Factory reset"
        color: "#071a3f"
        // Closed from its title bar, the app ends too, rather than staying in the background.
        onClosed: Qt.quit()
        implicitWidth: 640; implicitHeight: 620
        function px(n) { return Math.round(n) }

        component Label: Text {
            color: "white"
            font.family: "HarmonyOS Sans"
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
        component Field: Rectangle {
            id: field
            property alias text: input.text
            property alias input: input
            property string placeholder: ""
            signal accepted()
            anchors.horizontalCenter: parent.horizontalCenter
            width: 420; height: 54
            radius: height / 2
            color: Qt.rgba(1, 1, 1, input.activeFocus ? 0.2 : 0.13)
            border.width: 1.5
            border.color: input.activeFocus ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(1, 1, 1, 0.22)
            TextInput {
                id: input
                anchors { fill: parent; leftMargin: 24; rightMargin: 24 }
                verticalAlignment: TextInput.AlignVCenter
                horizontalAlignment: TextInput.AlignHCenter
                color: "white"
                font.pixelSize: 18
                echoMode: TextInput.Password
                passwordCharacter: "●"
                clip: true
                activeFocusOnTab: true
                maximumLength: 256
                onAccepted: field.accepted()
                onTextChanged: if (text.length > 0) app.notice = ""
            }
            Label { anchors.centerIn: parent; visible: input.text.length === 0; text: field.placeholder; color: Qt.rgba(1, 1, 1, 0.62); font.pixelSize: 17 }
        }
        component Action: Rectangle {
            id: action
            property string label: ""
            property bool ready: true
            property bool danger: false
            signal activated()
            anchors.horizontalCenter: parent.horizontalCenter
            width: 300; height: 52
            radius: height / 2
            color: !ready ? Qt.rgba(1, 1, 1, 0.16) : danger ? (hit.pressed ? "#b3261e" : "#d93025") : (hit.pressed ? "#dfe8ff" : "white")
            Label {
                anchors.centerIn: parent
                text: action.label
                color: !action.ready ? Qt.rgba(1, 1, 1, 0.5) : action.danger ? "white" : "#0b2a6b"
                font.pixelSize: 17; font.weight: Font.DemiBold
            }
            MouseArea { id: hit; anchors.fill: parent; enabled: action.ready; cursorShape: Qt.PointingHandCursor; onClicked: action.activated() }
        }
        component Quiet: Label {
            id: quiet
            signal activated()
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: 16; font.weight: Font.Medium
            color: Qt.rgba(1, 1, 1, 0.8)
            MouseArea { anchors { fill: parent; margins: -10 } cursorShape: Qt.PointingHandCursor; onClicked: quiet.activated() }
        }

        // ── What will happen ──
        Column {
            visible: app.step === 0
            anchors.centerIn: parent
            width: 520
            spacing: 16
            Label { width: parent.width; text: "Factory reset"; font.pixelSize: 36; font.weight: Font.DemiBold }
            Label {
                width: parent.width
                visible: app.checked && app.admin
                color: Qt.rgba(1, 1, 1, 0.86)
                font.pixelSize: 18
                text: "This erases every account on this device, with all of their files, photos and settings, along with saved Wi-Fi networks and paired Bluetooth devices.\n\nThis can’t be undone. Your device will restart and open first-time setup."
            }
            Label {
                width: parent.width
                visible: app.checked && !app.admin
                color: Qt.rgba(1, 1, 1, 0.86)
                font.pixelSize: 18
                text: "Only an administrator can reset this device. Ask an administrator to sign in and do this."
            }
            Item { width: 1; height: 10 }
            Action {
                visible: app.checked && app.admin
                label: "Continue"
                onActivated: { app.step = 1; first.input.forceActiveFocus() }
            }
            Quiet { text: app.checked && !app.admin ? "Close" : "Cancel"; onActivated: Qt.quit() }
        }

        // ── An administrator's password, twice ──
        Column {
            id: form
            readonly property bool mismatch: second.text.length > 0 && first.text !== second.text
            readonly property bool ready: first.text.length > 0 && first.text === second.text && !app.busy
            visible: app.step === 1
            anchors.centerIn: parent
            width: 520
            spacing: 14
            Label { width: parent.width; text: "Enter your password"; font.pixelSize: 32; font.weight: Font.DemiBold }
            Label { width: parent.width; text: "Type your administrator password twice to erase this device."; color: Qt.rgba(1, 1, 1, 0.86); font.pixelSize: 17 }
            Item { width: 1; height: 6 }
            Field { id: first; placeholder: "Password"; onAccepted: second.input.forceActiveFocus() }
            Field { id: second; placeholder: "Type it again"; onAccepted: app.erase() }
            Label {
                width: parent.width
                height: 26
                color: "#ffb4ab"
                font.pixelSize: 15; font.weight: Font.Medium
                text: app.notice.length > 0 ? app.notice : form.mismatch ? "Those passwords don’t match." : " "
            }
            Action { label: app.busy ? "Checking…" : "Erase everything"; danger: true; ready: form.ready; onActivated: app.erase() }
            Quiet { text: "Cancel"; onActivated: Qt.quit() }
        }

        // ── Restarting ──
        Column {
            visible: app.step === 2
            anchors.centerIn: parent
            width: 520
            spacing: 22
            Label { width: parent.width; text: "Restarting to erase this device"; font.pixelSize: 30; font.weight: Font.DemiBold }
            Label { width: parent.width; text: "This can take a few minutes. Please keep your device powered on."; color: Qt.rgba(1, 1, 1, 0.86); font.pixelSize: 18 }
            LoginActivity { anchors.horizontalCenter: parent.horizontalCenter; width: 170; height: 4 }
        }
        Shortcut { sequence: "Escape"; enabled: app.step < 2; onActivated: Qt.quit() }
    }
}

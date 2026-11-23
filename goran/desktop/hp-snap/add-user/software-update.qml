// HP-OS Software Update, opened from Settings > General: what's new, and installing it.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "."

ShellRoot {
    id: app
    readonly property string preview: Quickshell.env("HP_OS_UPDATE_PREVIEW")
    property var status: ({})
    property bool admin: false
    property bool asking: false
    property bool sending: false
    property string notice: ""
    property bool checking: false
    property real checkStarted: 0
    readonly property string checkError: String(app.status.checkError || "")
    readonly property string state: String(app.status.state || "idle")
    readonly property var offer: app.status.available || null
    readonly property bool busy: state === "downloading" || state === "installing" || state === "restoring"
    // How big the update is and about how long it takes on this connection (the updater measures both when it checks).
    property real now: Date.now()
    function sizeText(bytes) {
        return bytes >= 1e9 ? (bytes / 1e9).toFixed(1) + " GB" : Math.max(1, Math.round(bytes / 1e6)) + " MB"
    }
    function durationText(seconds) {
        const minutes = Math.round(seconds / 60)
        return seconds < 90 ? "about a minute" : minutes < 90 ? "about " + minutes + " minutes"
            : "about " + Math.round(minutes / 60) + " hours"
    }
    readonly property string sizeLine: {
        const offer = app.offer
        if (!offer) return ""
        const bytes = Number(offer.downloadBytes ?? -1), seconds = Number(offer.estimateSeconds ?? 0)
        if (bytes < 0) return ""
        const parts = [bytes > 0 ? app.sizeText(bytes) + " download" : "Nothing new to download"]
        if (seconds > 0) parts.push(app.durationText(seconds).replace(/^about/, "About") + " on this connection")
        return parts.join(" · ")
    }
    readonly property string timeLeft: {
        const offer = app.status.available || {}
        const seconds = Number(offer.estimateSeconds ?? 0), started = Number(app.status.started ?? 0)
        if (!app.busy || app.state === "restoring" || seconds <= 0 || started <= 0) return ""
        const left = seconds - (app.now / 1000 - started)
        return left > 45 ? app.durationText(left).replace(/^about/, "About") + " left" : "Almost done…"
    }

    Process {
        id: request
        property string message: ""
        property var answer: null
        property var then: null
        stdinEnabled: true
        command: ["/usr/bin/python3", "-I", Quickshell.shellPath("device-client.py"), "/run/hp-os/update.sock"]
        stdout: SplitParser { onRead: line => { try { request.answer = JSON.parse(line) } catch (error) {} } }
        onStarted: { request.write(request.message + "\n"); request.message = "" }
        onExited: { const done = request.then; request.then = null; if (done) done(request.answer); app.sendNext() }
    }
    // One request at a time. One asked for while another is under way waits its turn: dropping it left Update now
    // on "Checking…" for good when it landed during a status refresh.
    property var queued: []
    function sendNext() {
        if (request.running || app.queued.length === 0) return
        const job = app.queued[0]
        app.queued = app.queued.slice(1)
        app.send(job.message, job.done)
    }
    function send(message, done) {
        if (request.running) { app.queued = app.queued.concat([{ message: message, done: done }]); return }
        request.answer = null
        request.then = done
        request.message = JSON.stringify(message)
        request.running = true
    }
    function refresh() {
        // A regular look; skipped while something else is being asked, so looks never pile up.
        if (app.preview.length > 0 || app.sending || request.running) return
        app.send({ action: "status" }, answer => {
            if (!answer || !answer.ok) return
            app.status = answer.status
            app.admin = answer.admin === true
            // The check runs in the background; it is done once it has recorded a time after the button was pressed.
            if (app.checking && Number(answer.status.lastChecked || 0) >= app.checkStarted - 2) app.checking = false
        })
    }
    function perform(action) {
        if (password.text.length === 0 || app.sending) return
        const secret = password.text
        password.text = ""
        app.sending = true
        app.notice = ""
        if (app.preview.length > 0) { app.sending = false; app.asking = false; app.status = previews.downloading; return }
        app.send({ action: action, password: secret }, answer => {
            app.sending = false
            if (answer && answer.ok) { app.asking = false; app.refresh() }
            else app.notice = answer && answer.error ? answer.error : "The update couldn’t start."
        })
    }
    function checkNow() {
        if (app.preview.length > 0 || app.checking) return
        app.checking = true
        app.checkStarted = Date.now() / 1000
        checkLimit.restart()
        app.send({ action: "check" }, answer => {
            if (!answer || !answer.ok) { app.checking = false; app.notice = "Software Update isn’t available right now. Restart your device and try again." }
            app.refresh()
        })
    }
    Timer {
        id: checkLimit
        interval: 1500000      // the check also measures the update's size and download time
        onTriggered: if (app.checking) { app.checking = false; app.notice = "Checking took too long. Make sure you’re connected to the internet, then try again." }
    }
    QtObject {
        id: previews
        readonly property var offer: ({ version: "2026.11.20.1", date: "2026-11-20", downloadBytes: 742000000, estimateSeconds: 420, notes: "Files drag between your desktop, Files and the Dock.\nThe login screen starts faster.\nFixes for sleep and Wi-Fi." })
        readonly property var available: ({ state: "available", installed: "2026.11.18.1", available: offer })
        readonly property var downloading: ({ state: "downloading", installed: "2026.11.18.1", available: offer, progress: 42, started: Date.now() / 1000 - 120, message: "Preparing the update. This can take a while…" })
        readonly property var restart: ({ state: "restart", installed: "2026.11.20.1", progress: 100, message: "Restart to finish updating." })
        readonly property var error: ({ state: "error", installed: "2026.11.18.1", available: offer, message: "The update couldn’t be installed. Your device is back on the previous version." })
        readonly property var idle: ({ state: "idle", installed: "2026.11.20.1", previous: "2026.11.18.1" })
    }
    Timer { running: true; repeat: true; interval: 1500; triggeredOnStart: true; onTriggered: { app.now = Date.now(); app.refresh() } }
    Component.onCompleted: if (app.preview.length > 0) { app.status = previews[app.preview] || previews.idle; app.admin = Quickshell.env("HP_OS_UPDATE_ROLE") !== "standard" }

    // Light or dark and the accent, as the desktop has them, and its glass.
    WindowLook { id: hpLook }

    FloatingWindow {
        id: win
        visible: true
        title: "Software Update"
        color: "transparent"
        implicitWidth: 640; implicitHeight: 570
        // Niri blurs what is behind the window; the window lays a tint of HP-OS's surface over it.
        property Region glassArea: Region { item: body; radius: hpLook.radius }
        BackgroundEffect.blurRegion: hpLook.glass ? win.glassArea : null
        // No title bar here (the launcher turns Qt's off): closing the window some other way (Super+Q) ends the app,
        // so nothing is left running in the background.
        onClosed: Qt.quit()

        component Label: Text {
            color: hpLook.text
            font.family: hpLook.font
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            width: parent ? parent.width : implicitWidth
        }

        Rectangle {
            id: body
            anchors.fill: parent
            radius: hpLook.radius
            color: hpLook.body
            border.width: 1
            border.color: hpLook.rim
            Behavior on color { ColorAnimation { duration: 260 } }
            // With no title bar, the window moves by dragging anywhere on it outside its controls.
            MouseArea { anchors.fill: parent; onPressed: win.startSystemMove() }

            Item {
                anchors { left: parent.left; right: parent.right; top: parent.top; bottom: buttons.top; margins: 44; bottomMargin: 20 }
                Column {
                    anchors.centerIn: parent
                    width: parent.width
                    spacing: 12

                    // Where things stand, at a glance.
                    Rectangle {
                        readonly property bool trouble: app.state === "error"
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 80; height: 80; radius: 40
                        color: trouble ? hpLook.cautionSoft : hpLook.accentSoft
                        Glyph {
                            anchors.centerIn: parent
                            size: 40
                            color: parent.trouble ? hpLook.caution : hpLook.accent
                            name: parent.trouble ? "alert" : app.state === "restart" ? "restart"
                                : app.busy || app.offer ? "download" : "check"
                        }
                    }
                    Item { width: 1; height: 2 }

                    Label {
                        font.pixelSize: 26; font.weight: Font.DemiBold
                        text: app.state === "restart" ? "Ready to restart"
                            : app.busy ? (app.state === "restoring" ? "Restoring" : "Updating HP-OS")
                            : app.state === "error" ? "Update not installed"
                            : app.offer ? "HP-OS " + app.offer.version : "HP-OS is up to date"
                    }
                    Label {
                        color: hpLook.secondary
                        font.pixelSize: 15
                        lineHeight: 1.15
                        text: app.state === "restart" || app.busy || app.state === "error" ? String(app.status.message || "")
                            : app.offer ? "A new version is ready to install. Your files, apps and settings stay as they are."
                            : app.checking ? "Checking for updates…"
                            : app.status.installed ? "You’re on version " + app.status.installed + "." : "You’re on the latest version."
                    }

                    Label {
                        visible: app.sizeLine.length > 0 && !!app.offer && !app.busy && app.state !== "restart"
                        color: hpLook.tertiary
                        font.pixelSize: 13; font.weight: Font.Medium
                        text: app.sizeLine
                    }

                    // What's new
                    Rectangle {
                        visible: !!app.offer && !app.busy && app.state !== "restart" && !app.asking
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width; height: Math.min(190, notesColumn.implicitHeight + 36)
                        radius: 14
                        color: hpLook.fillQuiet
                        Flickable {
                            anchors { fill: parent; margins: 18 }
                            contentHeight: notesColumn.implicitHeight
                            clip: true
                            Column {
                                id: notesColumn
                                width: parent.width
                                spacing: 6
                                Text {
                                    text: "What’s new"
                                    color: hpLook.text
                                    font.family: hpLook.font
                                    font.pixelSize: 14; font.weight: Font.DemiBold
                                }
                                Text {
                                    id: notes
                                    width: parent.width
                                    color: hpLook.secondary
                                    font.family: hpLook.font
                                    font.pixelSize: 14
                                    lineHeight: 1.25
                                    wrapMode: Text.WordWrap
                                    text: app.offer ? String(app.offer.notes || "") : ""
                                }
                            }
                        }
                    }

                    // Progress
                    Item { width: 1; height: 4; visible: app.busy }
                    Rectangle {
                        visible: app.busy
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 380; height: 6; radius: 3
                        color: hpLook.fill
                        Rectangle {
                            width: parent.width * Math.max(0.03, Number(app.status.progress || 0) / 100)
                            height: parent.height; radius: 3
                            color: hpLook.accent
                            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                        }
                    }
                    Label {
                        visible: app.busy
                        color: hpLook.tertiary
                        font.pixelSize: 13
                        text: (app.timeLeft.length > 0 ? app.timeLeft + ". " : "") + "You can keep working. Please keep your device powered on."
                    }

                    // An administrator's password
                    PasswordField {
                        id: password
                        look: hpLook
                        visible: app.asking
                        anchors.horizontalCenter: parent.horizontalCenter
                        onAccepted: app.perform(app.offer ? "install" : "restore")
                        onTextChanged: if (text.length > 0) app.notice = ""
                    }
                    Label {
                        visible: !app.asking && !app.checking && !app.offer && !app.busy && app.state !== "restart"
                            && (app.notice.length > 0 || app.checkError.length > 0)
                        color: hpLook.caution
                        font.pixelSize: 14; font.weight: Font.Medium
                        text: app.notice.length > 0 ? app.notice
                            : app.checkError.indexOf("reach") >= 0 ? "Couldn’t check for updates. Make sure you’re connected to the internet, then try again."
                            : app.checkError
                    }
                    Label {
                        visible: app.asking || (!app.admin && !!app.offer && !app.busy && app.state !== "restart")
                        color: app.notice.length > 0 ? hpLook.caution : hpLook.secondary
                        font.pixelSize: 14; font.weight: Font.Medium
                        text: app.notice.length > 0 ? app.notice : app.asking ? " " : "Ask an administrator to install this update."
                    }
                }
            }

            // The actions, along the bottom: the way out first, the main action last, in the accent.
            Row {
                id: buttons
                anchors { bottom: parent.bottom; bottomMargin: 28; horizontalCenter: parent.horizontalCenter }
                spacing: 12
                readonly property int shown: {
                    let count = 0
                    for (const item of buttons.children) if (item.visible && item.label !== undefined) count++
                    return Math.max(1, count)
                }
                readonly property real each: Math.min(250, (body.width - 56 - (buttons.shown - 1) * 12) / buttons.shown)
                PillButton {
                    look: hpLook
                    width: buttons.each
                    visible: !app.asking
                    label: app.state === "restart" ? "Later" : "Close"
                    onActivated: Qt.quit()
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    visible: app.asking
                    label: "Back"
                    onActivated: { app.asking = false; app.notice = ""; password.text = "" }
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    primary: true
                    visible: !app.busy && app.state !== "restart" && !app.offer && !app.asking
                    label: app.checking ? "Checking…" : "Check for updates"
                    ready: !app.checking
                    onActivated: { app.notice = ""; app.checkNow() }
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    primary: true
                    visible: app.state === "restart"
                    label: "Restart now"
                    onActivated: Quickshell.execDetached(["/usr/bin/systemctl", "reboot"])
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    primary: true
                    visible: !app.busy && app.state !== "restart" && !!app.offer && app.admin
                    label: app.asking ? (app.sending ? "Checking…" : "Install now") : app.state === "error" ? "Try again" : "Update now"
                    ready: !app.asking || (password.text.length > 0 && !app.sending)
                    onActivated: {
                        if (app.asking) app.perform("install")
                        else { app.asking = true; password.forceActiveFocus() }
                    }
                }
            }
        }
        Shortcut { sequence: "Escape"; onActivated: { if (app.asking) { app.asking = false; password.text = "" } else Qt.quit() } }
    }
}

// HP-OS App Installer: opens an app downloaded as a .deb file and installs it, like a Mac's installer.
// The file comes in HP_OS_INSTALL_FILE; app-install-client.py hands it to the system helper already opened.
import QtQuick
import Quickshell
import Quickshell.Io
import "."

ShellRoot {
    id: app
    readonly property string file: Quickshell.env("HP_OS_INSTALL_FILE")
    readonly property string preview: Quickshell.env("HP_OS_INSTALL_PREVIEW")
    // opening, ready, asking, installing, done, error, refused
    property string stage: app.file.length > 0 || app.preview.length > 0 ? "opening" : "nofile"
    property var info: ({})
    property var progress: ({})
    property bool sending: false
    property string notice: ""
    readonly property string title: String(app.info.title || app.info.name || "This app")
    readonly property bool sameVersion: !!app.info.installed && app.info.installed === app.info.version
    readonly property bool admin: app.info.admin === true

    Process {
        id: request
        property string message: ""
        property var answer: null
        property var then: null
        property string withFile: ""
        stdinEnabled: true
        command: ["/usr/bin/python3", "-I", Quickshell.shellPath("app-install-client.py"), "/run/hp-os/app-install.sock"]
            .concat(request.withFile.length > 0 ? [request.withFile] : [])
        stdout: SplitParser { onRead: line => { try { request.answer = JSON.parse(line) } catch (error) {} } }
        onStarted: { request.write(request.message + "\n"); request.message = "" }
        onExited: { const done = request.then; request.then = null; if (done) done(request.answer); app.sendNext() }
    }
    property var queued: []
    function sendNext() {
        if (request.running || app.queued.length === 0) return
        const job = app.queued[0]
        app.queued = app.queued.slice(1)
        app.send(job.message, job.done, job.withFile)
    }
    function send(message, done, withFile) {
        if (request.running) { app.queued = app.queued.concat([{ message: message, done: done, withFile: withFile || "" }]); return }
        request.answer = null
        request.then = done
        request.withFile = withFile || ""
        request.message = JSON.stringify(message)
        request.running = true
    }

    function open() {
        if (app.preview.length > 0) return app.showPreview()
        app.stage = "opening"
        app.send({ action: "open" }, answer => {
            if (!answer || !answer.ok) {
                app.info = {}
                app.notice = answer && answer.error ? answer.error
                    : "App Installer isn’t ready yet. Install the latest HP-OS update, then try again."
                app.stage = "refused"
                return
            }
            app.info = answer
            app.stage = answer.allowed ? "ready" : "refused"
            app.notice = answer.allowed ? "" : String(answer.reason || "")
            app.look()
        }, app.file)
    }
    // An install already under way (the window was closed and opened again) is picked up where it is.
    function look() {
        app.send({ action: "status", token: app.info.token }, answer => {
            if (!answer || !answer.ok) return
            const status = answer.status || {}
            if (status.state === "installing" || status.state === "done") { app.progress = status; app.stage = status.state }
        })
    }
    function install() {
        if (password.text.length === 0 || app.sending) return
        const secret = password.text
        password.text = ""
        app.sending = true
        app.notice = ""
        if (app.preview.length > 0) { app.sending = false; app.progress = { progress: 40, message: "Installing " + app.title + "…" }; app.stage = "installing"; return }
        app.send({ action: "install", token: app.info.token, password: secret }, answer => {
            app.sending = false
            if (answer && answer.ok) { app.progress = { progress: 2, message: "Getting ready…" }; app.stage = "installing" }
            else app.notice = answer && answer.error ? answer.error : "The install couldn’t start."
        })
    }
    Timer {
        running: app.stage === "installing" && app.preview.length === 0
        repeat: true; interval: 700
        onTriggered: app.send({ action: "status", token: app.info.token }, answer => {
            if (!answer || !answer.ok) return
            const status = answer.status || {}
            app.progress = status
            if (status.state === "done") app.stage = "done"
            else if (status.state === "error") { app.notice = String(status.message || ""); app.stage = "error" }
        })
    }
    function launch(entry) {
        Quickshell.execDetached(["/usr/bin/gio", "launch", "/usr/share/applications/" + entry.id])
        Qt.quit()
    }

    QtObject {
        id: previews
        readonly property var ready: ({ ok: true, allowed: true, admin: true, title: "ChatGPT", version: "26.1103.60933", publisher: "OpenAI", size: "412 MB",
            about: "Chat, write and code with ChatGPT and Codex.", installed: "", icon: "" })
        readonly property var update: ({ ok: true, allowed: true, admin: true, title: "ChatGPT", version: "26.1120.10101", publisher: "OpenAI", size: "415 MB",
            about: "Chat, write and code with ChatGPT and Codex.", installed: "26.1103.60933", isUpdate: true, icon: "" })
        readonly property var refused: ({ ok: true, allowed: false, admin: true, title: "Steam", version: "1.0.0.87", publisher: "Valve Corporation", size: "20 MB",
            reason: "This version of the app is for Intel and AMD computers, and this laptop is an ARM computer. If the app’s maker offers a version for ARM (sometimes called arm64 or aarch64), download that one instead.", icon: "" })
        readonly property var standard: ({ ok: true, allowed: true, admin: false, title: "ChatGPT", version: "26.1103.60933", publisher: "OpenAI", size: "412 MB",
            about: "Chat, write and code with ChatGPT and Codex.", installed: "", icon: "" })
    }
    function showPreview() {
        const kind = app.preview
        app.info = previews[kind] || previews[kind.replace(/^(asking|installing|done|error)$/, "ready")] || previews.ready
        app.stage = kind === "refused" ? "refused" : kind === "standard" || kind === "update" ? "ready" : (["asking", "installing", "done", "error"].indexOf(kind) >= 0 ? kind : "ready")
        app.notice = kind === "refused" ? app.info.reason : kind === "error" ? "ChatGPT needs other software that couldn’t be found. Make sure you’re connected to the internet, then try again." : ""
        app.progress = kind === "done" ? { apps: [{ id: "chatgpt.desktop", name: "ChatGPT" }] } : { progress: 46, message: "Installing ChatGPT…" }
    }
    Component.onCompleted: if (app.stage === "opening") app.open()

    FloatingWindow {
        id: win
        visible: true
        title: "App Installer"
        color: "#071a3f"
        implicitWidth: 620; implicitHeight: 560

        component Label: Text {
            color: "white"
            font.family: "HarmonyOS Sans"
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            width: parent ? parent.width : implicitWidth
        }
        component Action: Rectangle {
            id: action
            property string label: ""
            property bool ready: true
            signal activated()
            anchors.horizontalCenter: parent.horizontalCenter
            width: 300; height: 52
            radius: height / 2
            color: !ready ? Qt.rgba(1, 1, 1, 0.16) : hit.pressed ? "#dfe8ff" : "white"
            Text {
                anchors.centerIn: parent
                text: action.label
                color: action.ready ? "#0b2a6b" : Qt.rgba(1, 1, 1, 0.5)
                font.family: "HarmonyOS Sans"
                font.pixelSize: 17; font.weight: Font.DemiBold
            }
            MouseArea { id: hit; anchors.fill: parent; enabled: action.ready; cursorShape: Qt.PointingHandCursor; onClicked: action.activated() }
        }
        component Quiet: Text {
            id: quiet
            signal activated()
            anchors.horizontalCenter: parent.horizontalCenter
            color: Qt.rgba(1, 1, 1, 0.8)
            font.family: "HarmonyOS Sans"
            font.pixelSize: 16; font.weight: Font.Medium
            MouseArea { anchors { fill: parent; margins: -10 } cursorShape: Qt.PointingHandCursor; onClicked: quiet.activated() }
        }

        Column {
            anchors.centerIn: parent
            width: 500
            spacing: 14

            // The app's own icon, or a parcel when it brings none.
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 104; height: 104
                visible: app.stage !== "nofile"
                Rectangle {
                    anchors.fill: parent
                    radius: 26
                    visible: icon.status !== Image.Ready
                    gradient: Gradient {
                        GradientStop { position: 0; color: "#3f86ff" }
                        GradientStop { position: 1; color: "#1747d6" }
                    }
                    // A box with its lid: drawn, so it needs no icon theme.
                    Rectangle { x: 26; y: 40; width: 52; height: 40; radius: 6; color: "white"; opacity: 0.95 }
                    Rectangle { x: 22; y: 30; width: 60; height: 14; radius: 5; color: "white" }
                    Rectangle { x: 48; y: 30; width: 8; height: 50; color: "#1f5be8"; opacity: 0.55 }
                }
                Image {
                    id: icon
                    anchors.fill: parent
                    source: app.info.icon ? "file://" + app.info.icon : ""
                    sourceSize: Qt.size(208, 208)
                    fillMode: Image.PreserveAspectFit
                    smooth: true; mipmap: true
                }
                // Done: a check over the icon.
                Rectangle {
                    visible: app.stage === "done"
                    anchors { right: parent.right; bottom: parent.bottom; margins: -6 }
                    width: 36; height: 36; radius: 18
                    color: "#16a37f"
                    border.width: 3; border.color: "#071a3f"
                    Text { anchors.centerIn: parent; text: "✓"; color: "white"; font.pixelSize: 19; font.weight: Font.Bold }
                }
            }

            Label {
                font.pixelSize: 32; font.weight: Font.DemiBold
                text: app.stage === "nofile" ? "App Installer"
                    : app.stage === "opening" ? "Opening…"
                    : app.stage === "done" ? app.title + " is installed"
                    : app.stage === "installing" ? "Installing " + app.title
                    : app.stage === "error" ? app.title + " wasn’t installed"
                    : app.stage === "refused" && !app.info.ok ? "Can’t open this file"
                    : app.title
            }
            Label {
                visible: !!app.info.version && ["ready", "asking", "refused"].indexOf(app.stage) >= 0
                color: Qt.rgba(1, 1, 1, 0.72)
                font.pixelSize: 15; font.weight: Font.Medium
                text: ["Version " + app.info.version, app.info.publisher ? "from " + app.info.publisher : "", app.info.size || ""]
                    .filter(part => part.length > 0).join("  ·  ")
            }
            Label {
                visible: text.length > 0
                color: Qt.rgba(1, 1, 1, 0.84)
                font.pixelSize: 17
                text: app.stage === "nofile" ? "Open an app’s installer file (it ends in .deb) to install it."
                    : app.stage === "ready" || app.stage === "asking"
                        ? (app.sameVersion ? "This version is already installed."
                           : app.info.isUpdate ? "Version " + app.info.installed + " is installed now. This updates it."
                           : String(app.info.about || ""))
                    : app.stage === "installing" ? String(app.progress.message || "")
                    : app.stage === "done" ? "Find it with your other apps, or open it now."
                    : ""
            }

            // Why it can't be installed, or what went wrong.
            Rectangle {
                visible: (app.stage === "refused" || app.stage === "error") && app.notice.length > 0
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width; height: why.implicitHeight + 36
                radius: 18
                color: Qt.rgba(1, 1, 1, 0.09)
                Text {
                    id: why
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 20 }
                    color: "white"
                    font.family: "HarmonyOS Sans"
                    font.pixelSize: 16
                    lineHeight: 1.2
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    text: app.notice
                }
            }

            // Progress
            Rectangle {
                visible: app.stage === "installing"
                anchors.horizontalCenter: parent.horizontalCenter
                width: 380; height: 6; radius: 3
                color: Qt.rgba(1, 1, 1, 0.2)
                Rectangle {
                    width: parent.width * Math.max(0.03, Number(app.progress.progress || 0) / 100)
                    height: parent.height; radius: 3
                    color: "white"
                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
            }
            Label {
                visible: app.stage === "installing"
                color: Qt.rgba(1, 1, 1, 0.66)
                font.pixelSize: 15
                text: "You can close this window. The install carries on."
            }

            // A word on trust, where the decision is made.
            Label {
                visible: app.stage === "ready" && !app.sameVersion
                color: Qt.rgba(1, 1, 1, 0.62)
                font.pixelSize: 14
                text: "Install apps only from companies you trust. An app you install can change this laptop for every account."
            }

            // An administrator's password
            Rectangle {
                visible: app.stage === "asking"
                anchors.horizontalCenter: parent.horizontalCenter
                width: 400; height: 54
                radius: height / 2
                color: Qt.rgba(1, 1, 1, password.activeFocus ? 0.2 : 0.13)
                border.width: 1.5
                border.color: password.activeFocus ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(1, 1, 1, 0.22)
                TextInput {
                    id: password
                    anchors { fill: parent; leftMargin: 24; rightMargin: 24 }
                    verticalAlignment: TextInput.AlignVCenter
                    horizontalAlignment: TextInput.AlignHCenter
                    color: "white"
                    font.pixelSize: 18
                    echoMode: TextInput.Password
                    passwordCharacter: "●"
                    clip: true
                    maximumLength: 256
                    onAccepted: app.install()
                    onTextChanged: if (text.length > 0) app.notice = ""
                }
                Text {
                    anchors.centerIn: parent
                    visible: password.text.length === 0
                    text: "Administrator password"
                    color: Qt.rgba(1, 1, 1, 0.62)
                    font.family: "HarmonyOS Sans"
                    font.pixelSize: 17
                }
            }
            Label {
                visible: app.stage === "asking" || (app.stage === "ready" && !app.admin)
                color: app.notice.length > 0 ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.78)
                font.pixelSize: 15; font.weight: Font.Medium
                text: app.notice.length > 0 ? app.notice : app.stage === "asking" ? " " : "Ask an administrator to install this app."
            }

            Item { width: 1; height: 4 }
            Action {
                visible: app.stage === "ready" && app.admin && !app.sameVersion
                label: app.info.isUpdate ? "Update" : "Install"
                onActivated: { app.notice = ""; app.stage = "asking"; password.forceActiveFocus() }
            }
            Action {
                visible: app.stage === "asking"
                label: app.sending ? "Checking…" : app.info.isUpdate ? "Update" : "Install"
                ready: password.text.length > 0 && !app.sending
                onActivated: app.install()
            }
            Repeater {
                model: app.stage === "done" ? (app.progress.apps || []).slice(0, 2) : []
                delegate: Action {
                    required property var modelData
                    label: (app.progress.apps || []).length > 1 ? "Open " + modelData.name : "Open"
                    onActivated: app.launch(modelData)
                }
            }
            Action {
                visible: app.stage === "error"
                label: "Try again"
                onActivated: { app.notice = ""; app.open() }
            }
            Quiet {
                visible: app.stage === "ready" && app.admin && app.sameVersion
                text: "Install again"
                onActivated: { app.notice = ""; app.stage = "asking"; password.forceActiveFocus() }
            }
            Quiet {
                visible: app.stage === "asking"
                text: "Back"
                onActivated: { app.stage = "ready"; app.notice = ""; password.text = "" }
            }
            Quiet {
                visible: app.stage !== "asking"
                text: app.stage === "done" ? "Done" : app.stage === "ready" ? "Cancel" : "Close"
                onActivated: Qt.quit()
            }
        }
        Shortcut { sequence: "Escape"; onActivated: { if (app.stage === "asking") { app.stage = "ready"; password.text = "" } else Qt.quit() } }
    }
}

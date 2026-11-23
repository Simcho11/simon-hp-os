// HP-OS App Installer: opens an app downloaded as a .deb file and installs it, like a Mac's installer.
// The file comes in HP_OS_INSTALL_FILE; app-install-client.py hands it to the system helper already opened.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
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
    // The file itself, and where it came from: its name and folder here, the website when the browser noted it.
    readonly property string fileName: app.file.replace(/^file:\/\//, "").split("/").pop()
    readonly property string fileFolder: { const parts = app.file.replace(/^file:\/\//, "").split("/"); return parts.length > 2 ? parts[parts.length - 2] : "" }
    readonly property string fileLine: !app.fileName ? ""
        : app.fileName + (app.info.origin ? "  ·  downloaded from " + app.info.origin : app.fileFolder ? "  ·  in " + app.fileFolder : "")
    // Nothing in a downloaded file is checked by HP-OS: its name, description and publisher are what its maker wrote.
    readonly property string caution: {
        const said = app.info.publisher ? " The file says it comes from " + app.info.publisher + "." : ""
        return "This app hasn’t been checked by HP-OS. Install it only if you trust where you got it." + said
    }

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
            about: "Chat, write and code with ChatGPT and Codex.", installed: "", icon: "", origin: "chatgpt.com", package: "chatgpt" })
        readonly property var update: ({ ok: true, allowed: true, admin: true, title: "ChatGPT", version: "26.1120.10101", publisher: "OpenAI", size: "415 MB",
            about: "Chat, write and code with ChatGPT and Codex.", installed: "26.1103.60933", isUpdate: true, icon: "", package: "chatgpt" })
        readonly property var source: ({ ok: true, allowed: true, admin: true, title: "Google Chrome", version: "142.0.7444.59", publisher: "Chrome Linux Team", size: "380 MB",
            about: "The web browser from Google.", installed: "", icon: "", origin: "google.com", package: "google-chrome-stable", addsSource: true })
        readonly property var refused: ({ ok: true, allowed: false, admin: true, title: "Steam", version: "1.0.0.87", publisher: "Valve Corporation", size: "20 MB",
            reason: "This version of the app is for Intel and AMD computers, and this laptop is an ARM computer. If the app’s maker offers a version for ARM (sometimes called arm64 or aarch64), download that one instead.", icon: "" })
        readonly property var standard: ({ ok: true, allowed: true, admin: false, title: "ChatGPT", version: "26.1103.60933", publisher: "OpenAI", size: "412 MB",
            about: "Chat, write and code with ChatGPT and Codex.", installed: "", icon: "" })
    }
    function showPreview() {
        const kind = app.preview
        app.info = previews[kind] || previews[kind.replace(/^(asking|installing|done|error)$/, "ready")] || previews.ready
        app.stage = kind === "refused" ? "refused" : kind === "standard" || kind === "update" || kind === "source" ? "ready" : (["asking", "installing", "done", "error"].indexOf(kind) >= 0 ? kind : "ready")
        app.notice = kind === "refused" ? app.info.reason : kind === "error" ? "ChatGPT needs other software that couldn’t be found. Make sure you’re connected to the internet, then try again." : ""
        app.progress = kind === "done" ? { apps: [{ id: "chatgpt.desktop", name: "ChatGPT" }] } : { progress: 46, message: "Installing ChatGPT…" }
    }
    Component.onCompleted: if (app.stage === "opening") app.open()

    // Light or dark and the accent, as the desktop has them, and its glass.
    WindowLook { id: hpLook }

    FloatingWindow {
        id: win
        visible: true
        title: "App Installer"
        color: "transparent"
        implicitWidth: 600; implicitHeight: 620
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
                anchors { left: parent.left; right: parent.right; top: parent.top; bottom: buttons.top; margins: 40; bottomMargin: 20 }
                Column {
                    anchors.centerIn: parent
                    width: parent.width
                    spacing: 12

                    // The app's own icon, or a parcel when it brings none.
                    Item {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 96; height: 96
                        visible: app.stage !== "nofile"
                        Rectangle {
                            anchors.fill: parent
                            radius: 24
                            visible: icon.status !== Image.Ready
                            color: hpLook.accentSoft
                            Glyph { anchors.centerIn: parent; name: "box"; size: 56; color: hpLook.accent }
                        }
                        Image {
                            id: icon
                            anchors.fill: parent
                            source: app.info.icon ? "file://" + app.info.icon : ""
                            sourceSize: Qt.size(192, 192)
                            fillMode: Image.PreserveAspectFit
                            smooth: true; mipmap: true
                        }
                        // Done: a check over the icon.
                        Rectangle {
                            visible: app.stage === "done"
                            anchors { right: parent.right; bottom: parent.bottom; margins: -6 }
                            width: 34; height: 34; radius: 17
                            color: hpLook.success
                            border.width: 3; border.color: hpLook.surface
                            Glyph { anchors.centerIn: parent; name: "check"; size: 20; color: "white" }
                        }
                    }
                    Item { width: 1; height: 2 }

                    Label {
                        font.pixelSize: 26; font.weight: Font.DemiBold
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
                        color: hpLook.secondary
                        font.pixelSize: 14; font.weight: Font.Medium
                        text: ["Version " + app.info.version, app.info.size || ""].filter(part => part.length > 0).join("  ·  ")
                    }
                    // Which file this is, and where it came from.
                    Label {
                        visible: app.fileLine.length > 0 && ["ready", "asking", "refused"].indexOf(app.stage) >= 0
                        color: hpLook.tertiary
                        font.pixelSize: 13
                        elide: Text.ElideMiddle
                        wrapMode: Text.NoWrap
                        text: app.fileLine
                    }
                    Label {
                        visible: text.length > 0
                        color: hpLook.secondary
                        font.pixelSize: 15
                        lineHeight: 1.15
                        text: app.stage === "nofile" ? "Open an app’s installer file (it ends in .deb) to install it."
                            : app.stage === "ready" || app.stage === "asking"
                                ? (app.sameVersion ? "This version is already installed."
                                   : app.info.isUpdate ? "“" + (app.info.package || app.title) + "” " + app.info.installed
                                       + " is already on this laptop. Installing this file replaces it."
                                   : String(app.info.about || ""))
                            : app.stage === "installing" ? String(app.progress.message || "")
                            : app.stage === "done" ? "Find it with your other apps, or open it now."
                            : ""
                    }

                    // Why it can't be installed, or what went wrong.
                    Rectangle {
                        visible: (app.stage === "refused" || app.stage === "error") && app.notice.length > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width; height: why.implicitHeight + 32
                        radius: 14
                        color: hpLook.fillQuiet
                        Text {
                            id: why
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 20 }
                            color: hpLook.text
                            font.family: hpLook.font
                            font.pixelSize: 15
                            lineHeight: 1.2
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                            text: app.notice
                        }
                    }

                    // Progress
                    Item { width: 1; height: 4; visible: app.stage === "installing" }
                    Rectangle {
                        visible: app.stage === "installing"
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 360; height: 6; radius: 3
                        color: hpLook.fill
                        Rectangle {
                            width: parent.width * Math.max(0.03, Number(app.progress.progress || 0) / 100)
                            height: parent.height; radius: 3
                            color: hpLook.accent
                            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                        }
                    }
                    Label {
                        visible: app.stage === "installing"
                        color: hpLook.tertiary
                        font.pixelSize: 13
                        text: "You can close this window. The install carries on."
                    }

                    // A word on trust, where the decision is made: what HP-OS knows, and what it doesn't.
                    Rectangle {
                        visible: app.stage === "ready" || app.stage === "asking"
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width; height: trust.implicitHeight + 28
                        radius: 14
                        color: app.info.addsSource ? hpLook.cautionSoft : hpLook.fillQuiet
                        Column {
                            id: trust
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 18 }
                            spacing: 8
                            Text {
                                width: parent.width
                                color: hpLook.secondary
                                font.family: hpLook.font
                                font.pixelSize: 13
                                lineHeight: 1.15
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                                text: app.caution
                            }
                            Text {
                                visible: app.info.addsSource === true
                                width: parent.width
                                color: hpLook.caution
                                font.family: hpLook.font
                                font.pixelSize: 13; font.weight: Font.Medium
                                lineHeight: 1.15
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignHCenter
                                text: "It also adds a software source of its own: from then on, its maker can install updates and "
                                    + "other software on this laptop, for every account. Many apps do this to stay up to date."
                            }
                        }
                    }

                    // An administrator's password
                    PasswordField {
                        id: password
                        look: hpLook
                        visible: app.stage === "asking"
                        anchors.horizontalCenter: parent.horizontalCenter
                        onAccepted: app.install()
                        onTextChanged: if (text.length > 0) app.notice = ""
                    }
                    Label {
                        visible: app.stage === "asking" || (app.stage === "ready" && !app.admin)
                        color: app.notice.length > 0 ? hpLook.caution : hpLook.secondary
                        font.pixelSize: 14; font.weight: Font.Medium
                        text: app.notice.length > 0 ? app.notice : app.stage === "asking" ? " " : "Ask an administrator to install this app."
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
                    visible: app.stage !== "asking"
                    label: app.stage === "done" ? "Done" : app.stage === "ready" ? "Cancel" : "Close"
                    onActivated: Qt.quit()
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    visible: app.stage === "asking"
                    label: "Back"
                    onActivated: { app.stage = "ready"; app.notice = ""; password.text = "" }
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    visible: app.stage === "ready" && app.admin && app.sameVersion
                    label: "Install again"
                    onActivated: { app.notice = ""; app.stage = "asking"; password.forceActiveFocus() }
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    primary: true
                    visible: app.stage === "error"
                    label: "Try again"
                    onActivated: { app.notice = ""; app.open() }
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    primary: true
                    visible: app.stage === "ready" && app.admin && !app.sameVersion
                    label: app.info.isUpdate ? "Update" : "Install"
                    onActivated: { app.notice = ""; app.stage = "asking"; password.forceActiveFocus() }
                }
                PillButton {
                    look: hpLook
                    width: buttons.each
                    primary: true
                    visible: app.stage === "asking"
                    label: app.sending ? "Checking…" : app.info.isUpdate ? "Update" : "Install"
                    ready: password.text.length > 0 && !app.sending
                    onActivated: app.install()
                }
                Repeater {
                    model: app.stage === "done" ? (app.progress.apps || []).slice(0, 2) : []
                    delegate: PillButton {
                        required property var modelData
                        look: hpLook
                        width: buttons.each
                        primary: true
                        label: (app.progress.apps || []).length > 1 ? "Open " + modelData.name : "Open"
                        onActivated: app.launch(modelData)
                    }
                }
            }
        }
        Shortcut { sequence: "Escape"; onActivated: { if (app.stage === "asking") { app.stage = "ready"; password.text = "" } else Qt.quit() } }
    }
}

// HP-OS "Add user": one question per screen, opened from the login screen's Add user button.
// Runs as the login screen's own unprivileged user. An administrator approves here (this app is the
// login screen's polkit agent), and accounts.py then creates a standard account.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import "."

ShellRoot {
    id: app

    readonly property bool preview: Quickshell.env("HP_OS_ADD_USER_PREVIEW") === "1"
    // The very first start of a new device: no one to ask, and this person becomes its administrator.
    readonly property bool firstBoot: Quickshell.env("HP_OS_FIRST_BOOT") === "1"
    readonly property string helper: Quickshell.env("HP_OS_ADD_USER_HELPER")
    readonly property string stateDir: Quickshell.env("HP_OS_ADD_USER_STATE") || (Quickshell.env("HOME") + "/.local/state/hp-os-add-user")
    readonly property string themeDir: "file:///opt/hp-os/login/themes/hpos/"
    readonly property int hour: new Date().getHours()
    readonly property string picture: themeDir + "hp-os-" + (hour >= 7 && hour < 19 ? "daybreak" : "harmony-night") + ".jpg"
    readonly property var expressive: [0.16, 1, 0.3, 1, 1, 1]

    // ── The answers ──
    property int step: firstBoot ? 5 : 0       // 5 hello (new device), 0 name, 1 picture, 2 password, 3 approve, 4 done
    property string fullName: ""
    readonly property var faces: ["daybreak", "tide", "bloom", "dune", "aurora"]
    property string face: ""                   // empty: their initial
    function faceUrl(name) { return name ? Quickshell.shellPath("pictures/" + name + ".jpg") : "" }
    function moveFace(by) {
        const choices = [""].concat(app.faces)
        app.face = choices[(choices.indexOf(app.face) + by + choices.length) % choices.length]
    }
    property string editedUsername: ""
    property bool editingUsername: false
    property int suffix: 0
    property string usernameState: "empty"     // empty | checking | ok | taken | invalid
    property string notice: ""
    property string phase: "waiting"           // waiting | input | checking | creating | preparing
    property real setupProgress: 0
    property bool prepared: false
    readonly property bool working: phase === "creating" || phase === "preparing"
    property string pendingPassword: ""
    property string signInPassword: ""         // Signs them in after Welcome; never written to disk storage.
    property bool leaving: false

    readonly property string firstName: fullName.trim().split(/\s+/)[0] || ""
    function derive(name) {
        return name.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
            .replace(/[^a-z0-9]+/g, "").replace(/^[0-9]+/, "").slice(0, 28)
    }
    readonly property string username: editingUsername ? editedUsername
        : derive(fullName) + (suffix > 0 ? String(suffix + 1) : "")
    readonly property bool usernameValid: /^[a-z_][a-z0-9_-]{0,31}$/.test(username)
    onUsernameChanged: {
        usernameState = username.length === 0 ? "empty" : usernameValid ? "checking" : "invalid"
        if (usernameValid) checkDelay.restart()
    }
    onFullNameChanged: if (!editingUsername) suffix = 0

    Timer { id: checkDelay; interval: 220; onTriggered: { lookup.running = false; lookup.command = ["/usr/bin/getent", "passwd", app.username]; lookup.running = true } }
    Process {
        id: lookup
        onExited: code => {
            if (lookup.command[2] !== app.username) return
            if (code !== 0) app.usernameState = "ok"
            else if (app.editingUsername) app.usernameState = "taken"
            else app.suffix++
        }
    }

    // ── Administrator approval ──
    LazyLoader { id: agent; active: !app.preview && !app.firstBoot; PolkitAgent {} }
    readonly property var flow: agent.item ? agent.item.flow : null
    Connections {
        target: app.flow
        function onIsResponseRequiredChanged() {
            if (app.flow.isResponseRequired) { app.phase = "input"; approval.focusField() }
        }
        function onAuthenticationFailed() {
            app.notice = "That password didn’t work. Try again."
            app.phase = "input"
            approval.shake()
            approval.focusField()
        }
        function onIsSuccessfulChanged() { if (app.flow.isSuccessful) { app.phase = "creating"; app.notice = "" } }
    }
    function approvers() {
        if (app.preview) return [{ displayName: "Simon" }, { displayName: "Simon Chong" }]
        return app.flow && app.flow.identities ? app.flow.identities : []
    }
    function approverName(who) { return who ? String(who.displayName || who.name || "Administrator") : "Administrator" }

    Process {
        id: create
        stdinEnabled: true
        environment: ({ "SHELL": "/bin/bash" })
        command: app.firstBoot ? ["/usr/bin/python3", "-I", Quickshell.shellPath("device-client.py"), "/run/hp-os/first-setup.sock"]
            : ["/usr/bin/pkexec", "/usr/bin/python3", "-I", app.helper]
        property var answer: null
        stdout: SplitParser {
            onRead: line => {
                let message = null
                try { message = JSON.parse(line) } catch (error) { return }
                if (message.progress !== undefined) { app.phase = "preparing"; app.setupProgress = message.progress }
                else create.answer = message
            }
        }
        onStarted: {
            create.write(JSON.stringify({ name: app.fullName.trim(), username: app.username, password: app.pendingPassword, picture: app.face }) + "\n")
            app.pendingPassword = ""
        }
        onExited: code => {
            const answer = create.answer
            if (answer && answer.ok) { app.prepared = answer.prepared === true; app.step = 4; return }
            app.signInPassword = ""
            app.step = 2
            app.notice = answer && answer.error ? answer.error
                : app.firstBoot ? "Your account couldn’t be created. Please try again."
                : "Approval was cancelled, so no account was created."
        }
    }
    function requestAccount(password) {
        app.notice = ""
        app.phase = app.firstBoot ? "creating" : "waiting"
        app.step = 3
        app.pendingPassword = password
        app.signInPassword = password
        if (app.preview) { app.pendingPassword = ""; if (app.firstBoot) mockCreate.start(); else mockAsk.start() } else create.running = true
    }
    function submitApproval(password) {
        app.notice = ""
        app.phase = "checking"
        if (app.preview) { mockCheck.wrong = password === "wrong"; mockCheck.start() } else if (app.flow) app.flow.submit(password)
    }
    function cancelApproval() {
        if (app.flow) app.flow.cancelAuthenticationRequest()
        if (create.running) create.running = false
        mockAsk.stop(); mockCheck.stop(); mockCreate.stop()
        app.signInPassword = ""
        app.step = 2
    }
    Timer { id: mockAsk; interval: 500; onTriggered: { app.phase = "input"; approval.focusField() } }
    Timer {
        id: mockCheck; property bool wrong: false; interval: 700
        onTriggered: {
            if (wrong) { app.phase = "input"; app.notice = "That password didn’t work. Try again."; approval.shake(); approval.focusField() }
            else { app.phase = "creating"; mockCreate.start() }
        }
    }
    Timer { id: mockCreate; interval: 700; onTriggered: { app.phase = "preparing"; mockSetup.start() } }
    Timer {
        id: mockSetup; interval: 350; repeat: true
        onTriggered: {
            app.setupProgress = Math.min(100, app.setupProgress + 12)
            if (app.setupProgress >= 100) { stop(); app.prepared = true; app.step = 4 }
        }
    }

    // ── Leaving: tell the login screen who was added (LoginLens.qml reads this file) ──
    // After Welcome the login screen signs them in with the password they just chose. It travels in a
    // private file in this user's memory-only runtime folder, and is removed moments later.
    readonly property string signInFile: Quickshell.env("XDG_RUNTIME_DIR") ? Quickshell.env("XDG_RUNTIME_DIR") + "/hp-os-add-user-sign-in.qml" : ""
    Process {
        id: signInWriter
        stdinEnabled: true
        command: ["/bin/sh", "-c", 'umask 077; IFS= read -r line; printf "%s\\n" "$line" > "$1"', "sh", app.signInFile]
        onStarted: {
            signInWriter.write("import QtQuick; Item { property string password: " + JSON.stringify(app.signInPassword) + " }\n")
            app.signInPassword = ""
        }
        onExited: app.writeHandoff(app.username, app.fullName.trim(), "file://" + app.signInFile)
    }
    Timer {
        id: forgetSignIn; interval: 2500
        onTriggered: { Quickshell.execDetached(["/bin/rm", "-f", app.signInFile]); Qt.quit() }
    }
    Process {
        id: handoff
        property bool signingIn: false
        onExited: handoff.signingIn ? forgetSignIn.start() : Qt.quit()
    }
    function continueToDesktop() {
        if (app.leaving) return
        app.leaving = true
        if (app.signInFile && app.signInPassword) signInWriter.running = true
        else app.writeHandoff(app.username, app.fullName.trim(), "")
    }
    function leave(login, name) { app.writeHandoff(login, name, "") }
    function writeHandoff(login, name, signIn) {
        handoff.signingIn = signIn.length > 0
        const icon = login ? app.faceUrl(app.face) : ""
        const text = "import QtQuick\nItem { property string login: " + JSON.stringify(login) + "; property string name: " + JSON.stringify(name)
            + "; property string icon: " + JSON.stringify(String(icon)) + "; property string signIn: " + JSON.stringify(signIn) + " }\n"
        handoff.command = ["/bin/sh", "-c", 'mkdir -p "$1" && printf %s "$2" > "$1/account.qml.new" && mv -f "$1/account.qml.new" "$1/account.qml"', "sh", app.stateDir, text]
        handoff.running = true
    }
    Component.onCompleted: {
        Quickshell.execDetached(["/bin/rm", "-f", app.stateDir + "/account.qml", app.signInFile])
        const start = Quickshell.env("HP_OS_ADD_USER_STEP")
        if (app.preview && start) {
            app.fullName = "Alex Morgan"
            app.step = Number(start)
            if (app.step === 3) mockAsk.start()
        }
    }

    FontLoader { source: app.themeDir + "fonts/HarmonyOS_Sans.ttf" }

    FloatingWindow {
        id: win
        visible: true
        title: "Add user"
        color: "black"
        implicitWidth: 1440
        implicitHeight: 900
        readonly property real d: Math.max(0.75, Math.min(2.2, Math.min(height / 1000, width / 1500)))
        function px(n) { return Math.round(n * d) }

        // ── Pieces ──
        component Label: Text {
            color: "white"
            font.family: "HarmonyOS Sans"
            horizontalAlignment: Text.AlignHCenter
            renderType: Text.NativeRendering
        }
        component Field: Rectangle {
            id: field
            property alias text: input.text
            property alias input: input
            property string placeholder: ""
            property bool secret: false
            property bool failed: false
            signal accepted()
            width: win.px(440); height: win.px(58)
            radius: height / 2
            color: Qt.rgba(1, 1, 1, input.activeFocus ? 0.2 : 0.13)
            border.width: Math.max(1, win.px(1.5))
            border.color: field.failed ? "#ff8a80" : input.activeFocus ? Qt.rgba(1, 1, 1, 0.75) : Qt.rgba(1, 1, 1, 0.22)
            Behavior on color { ColorAnimation { duration: 160 } }
            Behavior on border.color { ColorAnimation { duration: 160 } }
            TextInput {
                id: input
                anchors { fill: parent; leftMargin: win.px(26); rightMargin: win.px(26) }
                verticalAlignment: TextInput.AlignVCenter
                horizontalAlignment: TextInput.AlignHCenter
                color: "white"
                selectionColor: "#4f8dff"
                font.family: "HarmonyOS Sans"
                font.pixelSize: win.px(field.secret ? 20 : 19)
                echoMode: field.secret ? TextInput.Password : TextInput.Normal
                passwordCharacter: "●"
                clip: true
                activeFocusOnTab: true
                onAccepted: field.accepted()
            }
            Label {
                anchors.centerIn: parent
                visible: input.text.length === 0
                text: field.placeholder
                color: Qt.rgba(1, 1, 1, 0.62)
                font.pixelSize: win.px(18)
            }
        }
        component Primary: Rectangle {
            id: button
            property string label: ""
            property bool ready: true
            signal activated()
            width: win.px(240); height: win.px(54)
            radius: height / 2
            color: !ready ? Qt.rgba(1, 1, 1, 0.16) : hit.pressed ? "#dfe8ff" : "white"
            scale: hit.pressed && ready ? 0.97 : 1
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 160 } }
            Label {
                anchors.centerIn: parent
                text: button.label
                color: button.ready ? "#0b2a6b" : Qt.rgba(1, 1, 1, 0.5)
                font.pixelSize: win.px(18); font.weight: Font.DemiBold
            }
            MouseArea { id: hit; anchors.fill: parent; enabled: button.ready; cursorShape: Qt.PointingHandCursor; onClicked: button.activated() }
        }
        component Quiet: Label {
            id: quiet
            signal activated()
            font.pixelSize: win.px(16); font.weight: Font.Medium
            color: Qt.rgba(1, 1, 1, quietHit.containsMouse ? 1 : 0.78)
            MouseArea { id: quietHit; anchors { fill: parent; margins: -win.px(10) } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: quiet.activated() }
        }
        component Page: Item {
            id: page
            required property int index
            default property alias content: holder.data
            readonly property bool current: app.step === page.index
            anchors.fill: parent
            enabled: current
            visible: opacity > 0
            opacity: current ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            transform: Translate {
                x: page.current ? 0 : (app.step > page.index ? -win.px(70) : win.px(70))
                Behavior on x { NumberAnimation { duration: 480; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
            }
            Column {
                id: holder
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.round(parent.height * 0.36)
                spacing: win.px(14)
            }
        }
        component Title: Label {
            anchors.horizontalCenter: parent.horizontalCenter
            font.pixelSize: win.px(42); font.weight: Font.DemiBold
        }
        component Subtitle: Label {
            anchors.horizontalCenter: parent.horizontalCenter
            width: win.px(560)
            wrapMode: Text.WordWrap
            color: Qt.rgba(1, 1, 1, 0.84)
            font.pixelSize: win.px(19)
        }
        component Gap: Item { width: 1; property real size: 12; height: win.px(size) }
        component Note: Label {
            anchors.horizontalCenter: parent.horizontalCenter
            width: win.px(520)
            height: win.px(26)
            wrapMode: Text.WordWrap
            font.pixelSize: win.px(16); font.weight: Font.Medium
        }

        // ── The picture, out of focus, like the login screen behind this ──
        // Larger than the screen, so the blur's soft outer edge stays out of sight.
        Image {
            id: backdrop
            anchors { fill: parent; margins: -win.px(140) }
            source: app.picture
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(backdrop.width, backdrop.height)
            visible: false
        }
        MultiEffect {
            anchors.fill: backdrop
            source: backdrop
            blurEnabled: true; blur: 1; blurMax: 64
            saturation: 0.15
        }
        Rectangle { anchors.fill: parent; color: "#8a071a3f" }

        Row {
            x: win.px(36); y: win.px(30)
            spacing: win.px(12)
            Image {
                source: app.themeDir + "hp-logo.png"
                width: win.px(30); height: width
                sourceSize: Qt.size(width * 2, height * 2)
                anchors.verticalCenter: parent.verticalCenter
            }
            Label { text: "HP-OS"; font.pixelSize: win.px(20); font.weight: Font.Medium; font.letterSpacing: win.px(1.5); anchors.verticalCenter: parent.verticalCenter }
        }

        // ── Who this is becoming: stays on screen through every step ──
        LoginAvatar {
            id: avatar
            visible: app.step !== 5
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.17)
            width: win.px(app.step === 4 ? 132 : 112); height: width
            icon: app.faceUrl(app.face)
            name: app.fullName.trim() || " "
            fontFamily: "HarmonyOS Sans"
            Behavior on width { NumberAnimation { duration: 520; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
        }

        // ── Hello: only on a new device ──
        Page {
            index: 5
            Gap { size: 20 }
            Title { text: "Welcome to HP-OS" }
            Subtitle { text: "Let’s get your device ready. It only takes a few minutes." }
            Gap { size: 26 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Get started"
                onActivated: { app.step = 0; nameField.input.forceActiveFocus() }
            }
        }

        // ── 1. Name ──
        Page {
            index: 0
            Title { text: "What’s your name?" }
            Subtitle { text: app.firstBoot ? "You’ll be the administrator of this device." : "This is how you’ll appear on this device." }
            Gap { size: 14 }
            Field {
                id: nameField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Full name"
                input.maximumLength: 64
                input.onTextChanged: app.fullName = nameField.text
                onAccepted: nameNext.go()
                Component.onCompleted: if (!app.firstBoot) input.forceActiveFocus()
            }
            Field {
                id: usernameField
                visible: app.editingUsername
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Username"
                failed: app.usernameState === "taken" || app.usernameState === "invalid"
                input.maximumLength: 32
                input.inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhLowercaseOnly
                input.onTextChanged: app.editedUsername = usernameField.text
                onAccepted: nameNext.go()
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                height: win.px(26)
                spacing: win.px(10)
                visible: !app.editingUsername && app.username.length > 0
                Label { text: "Username: " + app.username; color: Qt.rgba(1, 1, 1, 0.8); font.pixelSize: win.px(16) }
                Quiet {
                    text: "Change"
                    color: "#bcd3ff"
                    onActivated: { usernameField.text = app.username; app.editingUsername = true; usernameField.input.forceActiveFocus() }
                }
            }
            Note {
                visible: app.editingUsername || app.username.length === 0
                color: app.usernameState === "taken" || app.usernameState === "invalid" ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.72)
                text: app.usernameState === "taken" ? "That username is already in use."
                    : app.usernameState === "invalid" ? "Use lowercase letters, numbers, hyphens or underscores."
                    : app.editingUsername ? "You’ll use this name behind the scenes." : " "
            }
            Gap { size: 8 }
            Primary {
                id: nameNext
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Continue"
                ready: app.fullName.trim().length > 0 && app.usernameState === "ok"
                function go() { if (ready) { app.step = 1; win.contentItem.forceActiveFocus() } }
                onActivated: go()
            }
            Quiet {
                anchors.horizontalCenter: parent.horizontalCenter
                text: app.firstBoot ? "Back" : "Cancel"
                onActivated: { if (app.firstBoot) app.step = 5; else app.leave("", "") }
            }
        }

        // ── 2. Picture ──
        Page {
            index: 1
            Title { text: "Choose a picture" }
            Subtitle { text: "Keep your initial, or pick one of these." }
            Gap { size: 20 }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: win.px(22)
                Repeater {
                    model: [""].concat(app.faces)
                    Item {
                        id: choice
                        required property string modelData
                        readonly property bool chosen: app.face === modelData
                        width: win.px(84); height: width
                        scale: chosen ? 1.08 : choiceHit.containsMouse ? 1.05 : 1
                        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width + win.px(12); height: width
                            radius: width / 2
                            color: "transparent"
                            border.width: Math.max(2, win.px(3))
                            border.color: "white"
                            opacity: choice.chosen ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 160 } }
                        }
                        LoginAvatar {
                            anchors.fill: parent
                            icon: app.faceUrl(choice.modelData)
                            name: app.fullName.trim() || " "
                            fontFamily: "HarmonyOS Sans"
                        }
                        MouseArea { id: choiceHit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.face = choice.modelData }
                    }
                }
            }
            Gap { size: 30 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Continue"
                onActivated: { app.step = 2; passwordField.input.forceActiveFocus() }
            }
            Quiet { anchors.horizontalCenter: parent.horizontalCenter; text: "Back"; onActivated: { app.step = 0; nameField.input.forceActiveFocus() } }
        }

        // ── 3. Password ──
        Page {
            index: 2
            Title { text: "Create a password" }
            Subtitle { text: "You’ll use it to sign in to HP-OS." }
            Gap { size: 14 }
            Field {
                id: passwordField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Password"; secret: true
                input.maximumLength: 256
                onAccepted: verifyField.input.forceActiveFocus()
            }
            Field {
                id: verifyField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Verify password"; secret: true
                failed: passwordPage.mismatch
                input.maximumLength: 256
                onAccepted: passwordPage.go()
            }
            Note {
                color: app.notice.length > 0 || passwordPage.mismatch ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.72)
                text: app.notice.length > 0 ? app.notice
                    : passwordPage.mismatch ? "Those passwords don’t match."
                    : "Use at least 8 characters."
            }
            Gap { size: 8 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Continue"
                ready: passwordPage.ready
                onActivated: passwordPage.go()
            }
            Quiet { anchors.horizontalCenter: parent.horizontalCenter; text: "Back"; onActivated: { app.notice = ""; app.step = 1; win.contentItem.forceActiveFocus() } }
        }
        QtObject {
            id: passwordPage
            readonly property bool mismatch: verifyField.text.length > 0 && verifyField.text !== passwordField.text
            readonly property bool ready: passwordField.text.length >= 8 && verifyField.text === passwordField.text
            function go() {
                if (!ready) return
                const password = passwordField.text
                passwordField.text = ""; verifyField.text = ""
                app.requestAccount(password)
            }
        }

        // ── 4. An administrator approves ──
        Page {
            index: 3
            Title { text: app.working ? "Setting up " + app.firstName + "’s desktop" : "Ask an administrator" }
            Subtitle {
                text: app.working ? "This can take a few minutes.\nPlease keep your device powered on."
                    : "An administrator of this device needs to approve " + (app.firstName || "this account") + "."
            }
            Gap { size: 14 }
            Row {
                visible: !app.working && approverList.count > 1
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: win.px(8)
                Repeater {
                    id: approverList
                    model: app.step === 3 ? app.approvers() : []
                    Rectangle {
                        required property var modelData
                        readonly property bool chosen: app.preview ? index === 0 : app.flow && app.flow.selectedIdentity === modelData
                        required property int index
                        width: chip.implicitWidth + win.px(32); height: win.px(40)
                        radius: height / 2
                        color: chosen ? "white" : Qt.rgba(1, 1, 1, 0.14)
                        Label { id: chip; anchors.centerIn: parent; text: app.approverName(parent.modelData); color: parent.chosen ? "#0b2a6b" : "white"; font.pixelSize: win.px(16); font.weight: Font.Medium }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (app.flow) app.flow.selectedIdentity = parent.modelData }
                    }
                }
            }
            Label {
                visible: !app.working && approverList.count === 1
                anchors.horizontalCenter: parent.horizontalCenter
                text: approverList.count === 1 ? app.approverName(app.approvers()[0]) : ""
                font.pixelSize: win.px(18); font.weight: Font.DemiBold
            }
            Item {
                id: approval
                anchors.horizontalCenter: parent.horizontalCenter
                width: win.px(440); height: win.px(58)
                property real shakeX: 0
                function focusField() { adminField.input.forceActiveFocus() }
                function shake() { shaking.restart() }
                SequentialAnimation {
                    id: shaking
                    NumberAnimation { target: approval; property: "shakeX"; to: -win.px(14); duration: 45 }
                    NumberAnimation { target: approval; property: "shakeX"; to: win.px(11); duration: 70 }
                    NumberAnimation { target: approval; property: "shakeX"; to: -win.px(6); duration: 60 }
                    NumberAnimation { target: approval; property: "shakeX"; to: 0; duration: 55 }
                }
                Field {
                    id: adminField
                    x: approval.shakeX
                    visible: app.phase === "input"
                    placeholder: "Administrator password"; secret: true
                    failed: app.notice.length > 0
                    input.maximumLength: 256
                    onAccepted: approveNext.go()
                }
                LoginActivity {
                    anchors.centerIn: parent
                    visible: app.phase === "waiting" || app.phase === "checking"
                    width: win.px(150); height: Math.max(3, win.px(4))
                }
                SetupBar {
                    anchors.centerIn: parent
                    visible: app.working
                    width: win.px(380); height: Math.max(4, win.px(6))
                    progress: app.setupProgress
                }
            }
            Note { color: "#ffb4ab"; text: app.notice.length > 0 && app.step === 3 ? app.notice : " " }
            Gap { size: 8 }
            Primary {
                id: approveNext
                visible: !app.working
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Approve"
                ready: app.phase === "input" && adminField.text.length > 0
                function go() {
                    if (!ready) return
                    const password = adminField.text
                    adminField.text = ""
                    app.submitApproval(password)
                }
                onActivated: go()
            }
            Quiet {
                visible: !app.working
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Back"
                onActivated: app.cancelApproval()
            }
        }

        // ── 5. Done ──
        Page {
            index: 4
            Title { text: "Welcome, " + app.firstName + "." }
            Subtitle { text: app.prepared ? "Your desktop is ready." : "Your account is ready. HP-OS will finish setting up your desktop next." }
            Gap { size: 22 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Continue"
                onActivated: app.continueToDesktop()
            }
        }

        // Where you are: four quiet dots.
        Row {
            visible: app.step < (app.firstBoot ? 3 : 4)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: win.px(46)
            spacing: win.px(10)
            Repeater {
                model: app.firstBoot ? 3 : 4
                Rectangle {
                    required property int index
                    width: win.px(index === app.step ? 22 : 8); height: win.px(8)
                    radius: height / 2
                    color: Qt.rgba(1, 1, 1, index === app.step ? 0.95 : 0.4)
                    Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                }
            }
        }

        // Continuing fades straight into the desktop's own start.
        Rectangle {
            anchors.fill: parent
            color: "black"
            opacity: app.leaving ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.InOutQuad } }
        }
        Shortcut {
            sequences: ["Return", "Enter"]
            enabled: app.step === 4 || app.step === 1 || app.step === 5
            onActivated: {
                if (app.step === 5) { app.step = 0; nameField.input.forceActiveFocus() }
                else if (app.step === 4) app.continueToDesktop()
                else { app.step = 2; passwordField.input.forceActiveFocus() }
            }
        }
        Shortcut { sequence: "Left"; enabled: app.step === 1; onActivated: app.moveFace(-1) }
        Shortcut { sequence: "Right"; enabled: app.step === 1; onActivated: app.moveFace(1) }
        Shortcut {
            sequence: "Escape"
            onActivated: {
                if (app.step === 0 && app.firstBoot) app.step = 5
                else if (app.step === 0) app.leave("", "")
                else if (app.step === 1) { app.step = 0; nameField.input.forceActiveFocus() }
                else if (app.step === 2) { app.step = 1; win.contentItem.forceActiveFocus() }
                else if (app.step === 3 && !app.working) app.cancelApproval()
            }
        }
    }
}

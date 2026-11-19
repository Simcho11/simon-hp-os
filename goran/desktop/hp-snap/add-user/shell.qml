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
    // 5 hello, 6 Wi-Fi, 7 software update (new device only), then 0 name, 1 picture, 2 password,
    // 9 recovery key, 8 time zone (new device only), 3 approve or set up, 4 done.
    // Opened as the recovery key's own window: 10 reset a forgotten password, 11 reset done (login screen),
    // or 12 an administrator's password, then 9 the new key (Settings).
    property int step: firstBoot ? 5 : resetMode ? 10 : newKeyMode ? 12 : 0
    // Where each step sits in the flow, so screens slide the way the person is going.
    function order(step) { return [0, 1, 2, 4, 5, -3, -2, -1, 3, 2.5, 0, 1, 0, -1.5][step] }
    property Item activePage: null
    // Set by the first-setup service just before the restart that finishes an update: Wi-Fi and the update are done,
    // so the welcome carries on at "What's your name?" instead of starting over.
    Loader { id: updatedMark; source: app.firstBoot ? "file:///var/lib/hp-os/welcome-updated.qml" : "" }
    readonly property bool justUpdated: updatedMark.status === Loader.Ready
    onJustUpdatedChanged: if (app.justUpdated && app.step === 5) { app.online = true; app.step = 0; Qt.callLater(() => nameField.input.forceActiveFocus()) }
    // Everything fades in when the window opens.
    property real appear: 0
    NumberAnimation on appear { from: 0; to: 1; duration: 1100; easing.type: Easing.OutCubic }
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
    LazyLoader { id: agent; active: !app.preview && !app.firstBoot && !app.recoveryMode; PolkitAgent {} }
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
    // ── A new device: Wi-Fi, then the newest HP-OS, before the first account (accounts.py --first-boot) ──
    property var networks: []
    property bool online: false
    property bool scanning: false
    property var chosenNetwork: null
    property bool joining: false
    property string wifiNotice: ""
    property string updatePhase: "checking"      // checking, installing, current, failed, restarting
    property string updateVersion: ""
    property real updateProgress: 0
    property string updateMessage: ""
    // How big the update is and about how long it takes here (measured by the updater when it checks).
    property real updateBytes: 0
    property real updateEstimate: 0      // seconds
    property real updateStarted: 0       // ms
    property real updateNow: 0
    function sizeText(bytes) {
        return bytes >= 1e9 ? (bytes / 1e9).toFixed(1) + " GB" : Math.max(1, Math.round(bytes / 1e6)) + " MB"
    }
    function durationText(seconds) {
        const minutes = Math.round(seconds / 60)
        return seconds < 90 ? "about a minute" : minutes < 90 ? "about " + minutes + " minutes"
            : "about " + Math.round(minutes / 60) + " hours"
    }
    readonly property string updateLeft: {
        if (app.updateEstimate <= 0 || app.updateStarted <= 0) return ""
        const left = app.updateEstimate - (app.updateNow - app.updateStarted) / 1000
        return left > 45 ? app.durationText(left).replace(/^about/, "About") + " left" : "Almost done…"
    }
    Process {
        id: welcomeRequest
        property string message: ""
        property var answer: null
        property var then: null
        stdinEnabled: true
        command: ["/usr/bin/python3", "-I", Quickshell.shellPath("device-client.py"), "/run/hp-os/first-setup.sock"]
        stdout: SplitParser { onRead: line => { try { welcomeRequest.answer = JSON.parse(line) } catch (error) {} } }
        onStarted: { welcomeRequest.write(welcomeRequest.message + "\n"); welcomeRequest.message = "" }
        onExited: { const done = welcomeRequest.then; welcomeRequest.then = null; if (done) done(welcomeRequest.answer || { ok: false }); app.askNext() }
    }
    // One request at a time; one asked for meanwhile waits its turn (dropping it could leave a step waiting for good).
    // Regular looks (optional) are skipped instead while another is under way, so they never pile up.
    property var askQueue: []
    function askNext() {
        if (welcomeRequest.running || app.askQueue.length === 0) return
        const job = app.askQueue[0]
        app.askQueue = app.askQueue.slice(1)
        app.ask(job.message, job.done)
    }
    function ask(message, done, optional) {
        if (app.preview) { mockWelcome.reply(message, done); return }
        if (welcomeRequest.running) { if (!optional) app.askQueue = app.askQueue.concat([{ message: message, done: done }]); return }
        welcomeRequest.answer = null
        welcomeRequest.then = done
        welcomeRequest.message = JSON.stringify(message)
        welcomeRequest.running = true
    }
    function startWifi() {
        app.step = 6
        app.wifiNotice = ""
        app.scanWifi()
    }
    function scanWifi() {
        app.scanning = true
        app.ask({ action: "wifi-list" }, answer => {
            app.scanning = false
            app.networks = answer.networks || []
            app.online = answer.online === true
            if (app.step !== 6 || app.chosenNetwork) return
            // Already online (a cable, or a network joined before): straight on to updates.
            if (app.online) { app.startUpdate(); return }
            // Already on a network that doesn't reach the internet yet, or wants a web sign-in first.
            if (app.networks.some(network => network.connected)) app.needInternet(answer.signIn, answer.connectivity)
        })
    }
    // What a network asks for: open and owe (Enhanced Open) nothing; psk, sae and wep a password; eap a username and
    // password (work, school, eduroam); a hidden one its name, and a password if it has one.
    function needsNothing(network) { return !!network && !network.hidden && (network.kind === "open" || network.kind === "owe" || (!network.kind && !network.secure)) }
    readonly property bool wifiReady: {
        const network = app.chosenNetwork
        if (!network || app.joining) return false
        const password = wifiPassword.text
        if (network.hidden) return wifiName.text.trim().length > 0 && (password.length === 0 || password.length >= 8)
        if (network.kind === "eap") return wifiUser.text.trim().length > 0 && password.length > 0
        if (network.kind === "wep") return password.length >= 5
        return password.length >= 8
    }
    function chooseNetwork(network) {
        app.wifiNotice = ""
        wifiPassword.text = ""; wifiUser.text = ""; wifiName.text = ""
        app.chosenNetwork = network
        if (app.needsNothing(network)) { app.joinWifi(); return }
        Qt.callLater(() => (network.hidden ? wifiName : network.kind === "eap" ? wifiUser : wifiPassword).input.forceActiveFocus())
    }
    function joinWifi() {
        const network = app.chosenNetwork
        if (!network || app.joining || (!app.needsNothing(network) && !app.wifiReady)) return
        app.joining = true
        app.wifiNotice = ""
        app.ask({ action: "wifi-join", ssid: network.hidden ? wifiName.text.trim() : network.ssid, kind: network.kind || "",
                  secure: network.secure, sae: network.sae, hidden: !!network.hidden,
                  user: network.kind === "eap" ? wifiUser.text.trim() : "", password: wifiPassword.text }, answer => {
            app.joining = false
            if (!answer.ok) { app.wifiNotice = answer.error || "Couldn’t join that network."; return }
            if (network.hidden) app.chosenNetwork = { ssid: wifiName.text.trim(), kind: wifiPassword.text ? "psk" : "open", secure: !!wifiPassword.text }
            wifiPassword.text = ""
            // On only once the internet really works; until then, sign in or wait.
            if (answer.connectivity === "full") { app.online = true; app.startUpdate() }
            else app.needInternet(answer.signIn, answer.connectivity)
        })
    }
    function skipWifi() { app.step = 0; nameField.input.forceActiveFocus() }

    // ── A Wi-Fi network that wants a web sign-in first (hotels, cafés, airports): its page opens full screen in Chrome,
    // which is on every HP-OS device, and setup carries on by itself as soon as the internet works. ──
    property string signInPage: ""
    property string signInNetwork: ""
    property bool signInOpen: false
    property string netState: "portal"          // portal: wants a web sign-in; otherwise connected but no internet yet
    property bool checkingNet: false
    property bool mockSignedIn: false
    readonly property string signInFolder: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hp-os-wifi-sign-in"
    function needInternet(page, state) {
        app.signInPage = page || "http://connectivity-check.ubuntu.com/"
        app.netState = state === "portal" ? "portal" : "offline"
        const current = app.chosenNetwork || app.networks.find(network => network.connected) || null
        app.signInNetwork = current ? current.ssid : ""
        app.step = 13
        signInWatch.start()
    }
    function checkInternet() {
        if (app.checkingNet) return
        app.checkingNet = true
        app.ask({ action: "wifi-connectivity" }, answer => { app.checkingNet = false; app.internetAnswer(answer) })
    }
    function internetAnswer(answer) {
        if (app.step !== 13) return
        if (answer.connectivity === "full") {
            signInWatch.stop()
            if (signInBrowser.running) signInBrowser.running = false
            app.online = true
            app.startUpdate()
            return
        }
        if (answer.connectivity === "portal") { app.netState = "portal"; if (answer.signIn) app.signInPage = answer.signIn }
        else if (!app.signInOpen) app.netState = "offline"
    }
    Process {
        id: signInBrowser
        // A throwaway profile in memory, gone when the window closes. What Chrome says goes to a log beside it, kept
        // until the next restart, in case the page doesn't appear.
        environment: ({ "HOME": app.signInFolder, "XDG_CONFIG_HOME": app.signInFolder + "/config" })
        command: ["/bin/sh", "-c", 'folder=$1; shift; mkdir -p "$folder" && cd "$folder" || exit 1; exec "$@" > "$folder.log" 2>&1',
            "sh", app.signInFolder, Quickshell.env("HP_OS_CHROME") || "google-chrome-stable", "--app=" + app.signInPage,
            "--user-data-dir=" + app.signInFolder, "--no-first-run", "--no-default-browser-check", "--disable-sync",
            "--disable-extensions", "--disable-background-networking", "--disable-component-update", "--password-store=basic",
            "--ozone-platform=wayland", "--disable-gpu", "--new-window", "--start-maximized"]
        onRunningChanged: {
            app.signInOpen = signInBrowser.running
            if (!signInBrowser.running) signInFront.stop()
        }
        onExited: code => {
            Quickshell.execDetached(["/bin/rm", "-rf", "--", app.signInFolder])
            // Gone before its page ever showed: say so, instead of looking like it's open.
            if (!app.signInShown && app.step === 13) app.signInNotice = "The sign-in page couldn’t open. Try again, or choose another network."
        }
    }
    property bool signInShown: false
    property string signInNotice: ""
    property int signInTries: 0
    function openSignIn() {
        app.signInNotice = ""
        if (app.preview) { app.signInOpen = true; mockSignIn.start(); return }
        if (signInBrowser.running) { app.signInTries = 0; signInFront.restart(); return }
        app.signInShown = false
        app.signInTries = 0
        signInBrowser.running = true
        signInFront.restart()
    }
    // The page's window is found in the login screen's compositor and brought to the front: it could open behind setup.
    // No window after fifteen seconds means it didn't open; Chrome is stopped so the person can try again.
    Timer {
        id: signInFront; interval: 1000; repeat: true
        onTriggered: {
            app.signInTries++
            if (app.signInTries > 15) {
                stop()
                if (!app.signInShown) {
                    signInBrowser.running = false
                    app.signInNotice = "The sign-in page didn’t appear. Try again, or choose another network."
                }
                return
            }
            if (!signInFocus.running) signInFocus.running = true
        }
    }
    Process {
        id: signInFocus
        command: ["/bin/sh", "-c", 'niri=/opt/hp-os/niri-patch/result-hpos/bin/niri
            socket=${NIRI_SOCKET:-$(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/niri.*.sock 2>/dev/null | head -n 1)}
            [ -x "$niri" ] && [ -S "$socket" ] || exit 2
            id=$(NIRI_SOCKET="$socket" "$niri" msg --json windows | /usr/bin/python3 -I -c \'import json, sys; found = [w["id"] for w in json.load(sys.stdin) if str(w.get("app_id") or "").startswith("chrome-")]; print(found[-1] if found else "")\')
            [ -n "$id" ] || exit 1
            NIRI_SOCKET="$socket" "$niri" msg action focus-window --id "$id"']
        onExited: code => {
            if (code === 0) { app.signInShown = true; signInFront.stop() }
            else if (code === 2) { app.signInShown = true; signInFront.stop() }    // No way to look: trust it opened.
        }
    }
    Timer { id: mockSignIn; interval: 5000; onTriggered: { app.mockSignedIn = true; app.signInOpen = false } }
    Timer {
        id: signInWatch; interval: 3000; repeat: true
        onTriggered: app.checkInternet()
    }
    function leaveSignIn(otherNetwork) {
        signInWatch.stop()
        if (signInBrowser.running) signInBrowser.running = false
        if (otherNetwork) { app.chosenNetwork = null; app.step = 6; app.scanWifi() }
        else app.skipWifi()
    }
    function startUpdate() {
        app.step = 7
        app.updatePhase = "checking"
        app.ask({ action: "update-check" }, answer => {
            const status = answer.status || {}
            if (status.available && status.available.version) {
                app.updateVersion = String(status.available.version)
                app.updateBytes = Number(status.available.downloadBytes || 0)
                app.updateEstimate = Number(status.available.estimateSeconds || 0)
                app.updateStarted = Date.now()
                app.updateNow = Date.now()
                app.updatePhase = "installing"
                app.updateProgress = 0
                app.updateMessage = "Downloading…"
                app.ask({ action: "update-install" }, () => updatePoll.start())
            } else if (status.checkError) {
                app.updatePhase = "failed"
                app.updateMessage = "Couldn’t check for updates. You can update later in Settings."
            } else {
                app.updatePhase = "current"
                updateDone.start()
            }
        })
    }
    Timer {
        id: updatePoll; interval: 2000; repeat: true
        onTriggered: app.ask({ action: "update-status" }, answer => {
            app.updateNow = Date.now()
            const status = answer.status || {}
            app.updateProgress = Number(status.progress || app.updateProgress)
            app.updateMessage = String(status.message || app.updateMessage)
            if (status.state === "restart") {
                updatePoll.stop()
                app.updatePhase = "restarting"
                app.ask({ action: "restart" }, () => {})
            } else if (status.state === "error") {
                updatePoll.stop()
                app.updatePhase = "failed"
                app.updateMessage = String(status.message || "The update couldn’t be installed.") + " You can update later in Settings."
            }
        }, true)
    }
    Timer { id: updateDone; interval: 1400; onTriggered: if (app.step === 7) app.skipWifi() }
    // Preview: the same time zone list a new device shows, read by accounts.py from this computer's own zone files.
    Process {
        id: previewZones
        property var done: null
        function load(callback) { previewZones.done = callback; previewZones.running = true }
        command: ["/usr/bin/python3", "-I", "-c",
            "import importlib.util, json, sys\n" +
            "spec = importlib.util.spec_from_file_location('accounts', sys.argv[1])\n" +
            "accounts = importlib.util.module_from_spec(spec); spec.loader.exec_module(accounts)\n" +
            "print(json.dumps({'ok': True, 'zones': accounts.time_zones(), 'current': accounts.current_zone()}))",
            Quickshell.shellPath("accounts.py")]
        stdout: StdioCollector {
            onStreamFinished: {
                let answer = { ok: true, zones: [], current: "" }
                try { answer = JSON.parse(this.text) } catch (e) {}
                if (previewZones.done) previewZones.done(answer)
            }
        }
    }
    // Preview: a pretend network list and update, for designing these screens.
    QtObject {
        id: mockWelcome
        function reply(message, done) {
            const a = message.action
            if (a === "wifi-list") done({ ok: true, online: false, networks: [
                { ssid: "Simon’s Wi-Fi", signal: 92, secure: true }, { ssid: "HP Guest", signal: 71, secure: false },
                { ssid: "Studio 5G", signal: 58, secure: true }, { ssid: "Café Wi-Fi", signal: 44, secure: false, kind: "open" },
                { ssid: "HP Corporate", signal: 66, secure: true, kind: "eap", enterprise: true } ] })
            else if (a === "wifi-join") mockLater.run(() => done(message.ssid === "Café Wi-Fi"
                ? { ok: true, online: false, connectivity: "portal", signIn: "http://connectivity-check.ubuntu.com/" }
                : message.ssid === "Studio 5G" ? { ok: true, online: false, connectivity: "none" }
                : message.kind === "eap" && message.password !== "secret" ? { ok: false, error: "Couldn’t join HP Corporate. Check your username and password and try again." }
                : { ok: true, online: true, connectivity: "full" }))
            else if (a === "wifi-connectivity") done({ ok: true, connectivity: app.mockSignedIn ? "full" : app.netState === "portal" ? "portal" : "none" })
            else if (a === "timezone-list") previewZones.load(done)
            else if (a === "recovery-key") done({ ok: true, key: mockRecovery.key })
            else if (a === "update-check") mockLater.run(() => done({ ok: true, status: { available: { version: "2026.11.19.1", downloadBytes: 742000000, estimateSeconds: 420 } } }))
            else if (a === "update-status") { mockLater.progress = Math.min(100, mockLater.progress + 9)
                done({ ok: true, status: { state: mockLater.progress >= 100 ? "restart" : "downloading", progress: mockLater.progress,
                                           message: "Preparing the update. This can take a while…" } }) }
            else done({ ok: true })
        }
    }
    Timer { id: mockLater; property var job: null; property real progress: 5; interval: 900; function run(job) { mockLater.job = job; start() } onTriggered: if (job) job() }

    // ── Time zone (a new device): the whole device keeps time by it ──
    property var zones: []
    property string zoneSearch: ""
    property string chosenZone: ""
    property string zoneNotice: ""
    property bool settingZone: false
    property string heldPassword: ""           // From the password screen, until the time zone is chosen.
    function plain(text) { return String(text).normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/−/g, "-").toLowerCase() }
    // Best first: a time name (PST) or the start of a city, state or country beats a word found somewhere inside,
    // and common places come before small ones that match as well. Every word typed has to match something.
    function zoneScore(place, words) {
        const city = app.plain(place.city), country = app.plain(place.country), region = app.plain(place.region)
        const names = " " + app.plain(place.names || "").replace(/[^a-z0-9]+/g, " ") + " "
        const abbr = (place.abbr || []).map(name => app.plain(name))
        const spaced = text => " " + text.replace(/[^a-z0-9+-]+/g, " ") + " "
        const offset = app.plain(app.offsetText(place.offset)), zone = app.plain(place.zone)
        let total = 0
        for (const word of words) {
            let best = 0
            if (abbr.indexOf(word) >= 0) best = 8
            else if (city === word || country === word) best = 7
            else if (spaced(city).indexOf(" " + word) >= 0) best = 6
            else if (names.indexOf(" " + word + " ") >= 0) best = 7
            else if (names.indexOf(" " + word) >= 0) best = 5
            else if (spaced(country).indexOf(" " + word) >= 0) best = 5
            else if (spaced(region).indexOf(" " + word) >= 0) best = 3
            else if ([offset, offset.split(":")[0]].some(text => text === word || text === "gmt" + word)) best = 3
            else if (city.indexOf(word) >= 0 || country.indexOf(word) >= 0) best = 2
            else if (zone.indexOf(word) >= 0) best = 1
            if (best === 0) return 0
            total += best
        }
        return total + 2 * Number(place.common || 0)
    }
    readonly property var zoneMatches: {
        const words = app.plain(app.zoneSearch).replace(/\btime\b/g, " ").replace(/\butc/g, "gmt").split(/[\s,]+/).filter(word => word.length > 0)
        if (words.length === 0) return app.zones
        return app.zones.map(place => ({ place: place, score: app.zoneScore(place, words) }))
            .filter(found => found.score > 0)
            .sort((a, b) => b.score - a.score)      // Stable: equal scores keep the list's country order.
            .map(found => found.place)
    }
    readonly property var chosenPlace: app.zones.find(place => place.zone === app.chosenZone) || null
    function offsetText(minutes) {
        if (!minutes) return "GMT"
        const size = Math.abs(minutes)
        return "GMT" + (minutes > 0 ? "+" : "−") + Math.floor(size / 60) + (size % 60 ? ":" + String(size % 60).padStart(2, "0") : "")
    }
    function timeThere(minutes) {
        const there = new Date(Date.now() + minutes * 60000)
        const hours = there.getUTCHours(), mins = String(there.getUTCMinutes()).padStart(2, "0")
        return (hours % 12 || 12) + ":" + mins + (hours < 12 ? " AM" : " PM")
    }
    function placeName(place) { return place.country === place.city ? place.city : place.country + " · " + place.city }
    function chooseTimeZone(password) {
        app.heldPassword = password
        app.zoneNotice = ""
        app.zoneSearch = ""
        zoneSearchField.text = ""
        app.step = 8
        Qt.callLater(() => zoneSearchField.input.forceActiveFocus())
        app.ask({ action: "timezone-list" }, answer => {
            app.zones = answer.zones || []
            // Keep what the device already has only if it is a real place; a bare UTC means nobody chose it.
            const current = String(answer.current || "")
            if (!app.chosenZone && app.zones.some(place => place.zone === current)) app.chosenZone = current
            if (app.zones.length === 0) app.zoneNotice = "The time zone list couldn’t be loaded. You can set it later."
        })
    }
    function confirmTimeZone() {
        if (app.settingZone) return
        if (!app.chosenZone) { app.finishTimeZone(); return }      // Only when the list couldn't be loaded.
        app.settingZone = true
        app.zoneNotice = ""
        app.ask({ action: "timezone-set", zone: app.chosenZone }, answer => {
            app.settingZone = false
            if (answer.ok) app.finishTimeZone()
            else app.zoneNotice = answer.error || "The time zone couldn’t be set."
        })
    }
    function finishTimeZone() {
        const password = app.heldPassword
        app.heldPassword = ""
        app.requestAccount(password)
    }
    function leaveTimeZone() {
        app.zoneNotice = ""
        if (app.recoveryKey) { app.step = 9; return }
        app.heldPassword = ""
        app.step = 2
        passwordField.input.forceActiveFocus()
    }

    // ── The recovery key (hp-os-recovery keeps only its hash) ──
    // A new device shows it once, after the password. The login screen's "Forgot your password?" opens this app
    // as HP_OS_RECOVERY=reset:<login> to set a new password with it; Settings opens it as "new" to replace a lost one.
    readonly property string recovery: Quickshell.env("HP_OS_RECOVERY")
    readonly property bool resetMode: app.recovery.indexOf("reset:") === 0
    readonly property bool newKeyMode: app.recovery === "new"
    readonly property bool recoveryMode: app.resetMode || app.newKeyMode
    readonly property string recoveryLogin: app.resetMode ? app.recovery.slice(6) : app.newKeyMode ? Quickshell.env("USER") : ""
    property string recoveryKey: ""
    property var recoveryQr: []
    property bool showQr: false
    property string usbState: ""               // "", saving, saved, failed
    property string usbMessage: ""
    property var usbAnswer: null
    property string recoveryNotice: ""
    property bool recoveryBusy: false
    Process {
        id: recoveryRequest
        property string message: ""
        property var answer: null
        property var then: null
        stdinEnabled: true
        command: ["/usr/bin/python3", "-I", Quickshell.shellPath("device-client.py"), "/run/hp-os/recovery.sock"]
        stdout: SplitParser { onRead: line => { try { recoveryRequest.answer = JSON.parse(line) } catch (error) {} } }
        onStarted: { recoveryRequest.write(recoveryRequest.message + "\n"); recoveryRequest.message = "" }
        onExited: { const done = recoveryRequest.then; recoveryRequest.then = null; if (done) done(recoveryRequest.answer || { ok: false }); app.askRecoveryNext() }
    }
    property var recoveryQueue: []
    function askRecoveryNext() {
        if (recoveryRequest.running || app.recoveryQueue.length === 0) return
        const job = app.recoveryQueue[0]
        app.recoveryQueue = app.recoveryQueue.slice(1)
        app.askRecovery(job.message, job.done)
    }
    function askRecovery(message, done) {
        if (app.preview) { mockRecovery.reply(message, done); return }
        if (recoveryRequest.running) { app.recoveryQueue = app.recoveryQueue.concat([{ message: message, done: done }]); return }
        recoveryRequest.answer = null
        recoveryRequest.then = done
        recoveryRequest.message = JSON.stringify(message)
        recoveryRequest.running = true
    }
    // The QR code holds just the key, drawn here by qrencode (from stdin, so the key never shows in a process list).
    Process {
        id: qrMaker
        stdinEnabled: true
        command: [Quickshell.env("HP_OS_QRENCODE") || "qrencode", "-t", "ASCII", "-m", "0", "-l", "M"]
        stdout: StdioCollector {
            onStreamFinished: app.recoveryQr = this.text.split("\n").filter(line => line.length > 0).map(line => {
                let row = ""
                for (let i = 0; i < line.length; i += 2) row += line.charAt(i) === "#" ? "1" : "0"
                return row
            })
        }
        onStarted: { qrMaker.write(app.recoveryKey); qrMaker.stdinEnabled = false }
    }
    function useRecoveryKey(key) {
        app.recoveryKey = key
        app.recoveryQr = []
        app.showQr = false
        app.usbState = ""; app.usbMessage = ""
        qrMaker.stdinEnabled = true
        qrMaker.running = true
    }
    function showRecoveryKey(password) {
        app.heldPassword = password
        if (app.recoveryKey) { app.step = 9; return }
        app.ask({ action: "recovery-key" }, answer => {
            if (answer.ok && answer.key) { app.useRecoveryKey(String(answer.key)); app.step = 9 }
            else app.chooseTimeZone(app.heldPassword)      // A device without the recovery helper goes straight on.
        })
    }
    function recoveryKeySaved() {
        if (app.firstBoot) app.chooseTimeZone(app.heldPassword)
        else Qt.quit()
    }
    // Saving shows for at least a moment, so a quick save still reads as saved.
    function saveToUsb() {
        if (app.usbState === "saving" || !app.recoveryKey) return
        app.usbState = "saving"; app.usbMessage = ""; app.usbAnswer = null
        usbMinimum.restart()
        app.askRecovery({ action: "save-usb", key: app.recoveryKey }, answer => { app.usbAnswer = answer; app.usbFinished() })
    }
    Timer { id: usbMinimum; interval: 1200; onTriggered: app.usbFinished() }
    function usbFinished() {
        const answer = app.usbAnswer
        if (!answer || usbMinimum.running) return
        app.usbAnswer = null
        if (answer.ok) { app.usbState = "saved"; app.usbMessage = "Saved to " + (answer.saved || "the USB stick") + ". You can remove it." }
        else { app.usbState = "failed"; app.usbMessage = answer.error || "The key couldn’t be saved. Try again." }
    }
    function resetPassword(key, password) {
        if (app.recoveryBusy) return
        app.recoveryBusy = true; app.recoveryNotice = ""
        app.askRecovery({ action: "reset", user: app.recoveryLogin, key: key, password: password }, answer => {
            app.recoveryBusy = false
            if (answer.ok) { app.step = 11; return }
            app.recoveryNotice = answer.error || "The password couldn’t be reset. Nothing was changed."
            keyField.input.forceActiveFocus()
        })
    }
    function makeNewKey(password) {
        if (app.recoveryBusy) return
        app.recoveryBusy = true; app.recoveryNotice = ""
        app.askRecovery({ action: "new", password: password }, answer => {
            app.recoveryBusy = false
            if (answer.ok && answer.key) { app.useRecoveryKey(String(answer.key)); app.step = 9; return }
            app.recoveryNotice = answer.error || "A new key couldn’t be made. Nothing was changed."
            ownPasswordField.input.forceActiveFocus()
        })
    }
    // Their name, for the picture at the top.
    Process {
        id: whoIs
        command: ["/usr/bin/getent", "passwd", app.recoveryLogin]
        stdout: StdioCollector { onStreamFinished: { const fields = this.text.split(":"); if (fields.length > 4) app.fullName = fields[4].split(",")[0] || fields[0] } }
    }
    QtObject {
        id: mockRecovery
        readonly property string key: "7KQM-3XRA-PL9D-W2HF-8TVN-C4ZE"
        property var pending: null
        function reply(message, done) {
            const a = message.action
            if (a === "save-usb") later(() => done({ ok: true, saved: "SanDisk 3.2Gen1" }), 1600)
            else if (a === "reset") later(() => done(String(message.key).replace(/[^A-Za-z0-9]/g, "").toUpperCase() === key.replace(/-/g, "")
                ? { ok: true } : { ok: false, error: "That recovery key isn’t right. Check it and try again." }), 800)
            else if (a === "new") later(() => done(message.password === "wrong" ? { ok: false, error: "That password isn’t correct." } : { ok: true, key: key }), 800)
            else done({ ok: false })
        }
        function later(job, ms) { mockRecoveryLater.job = job; mockRecoveryLater.interval = ms; mockRecoveryLater.restart() }
    }
    Timer { id: mockRecoveryLater; property var job: null; onTriggered: if (job) job() }

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
        if (app.recoveryMode) {
            if (app.recoveryLogin) whoIs.running = true
            Qt.callLater(() => (app.resetMode ? keyField : ownPasswordField).input.forceActiveFocus())
            if (app.preview && Quickshell.env("HP_OS_ADD_USER_STEP") === "9") { app.useRecoveryKey(mockRecovery.key); app.step = 9 }
            return
        }
        Quickshell.execDetached(["/bin/rm", "-f", app.stateDir + "/account.qml", app.signInFile])
        const start = Quickshell.env("HP_OS_ADD_USER_STEP")
        if (app.preview && start) {
            app.fullName = "Alex Morgan"
            app.step = Number(start)
            if (app.step === 3) mockAsk.start()
            if (app.step === 6) app.scanWifi()
            if (app.step === 7) app.startUpdate()
            if (app.step === 8) app.chooseTimeZone("previewpassword")
            if (app.step === 9) { app.step = 2; app.showRecoveryKey("previewpassword") }
            if (app.step === 13) { app.chosenNetwork = { ssid: "Café Wi-Fi", secure: false, kind: "open" }; app.needInternet("", Quickshell.env("HP_OS_PREVIEW_NET") || "portal") }
            if (app.step === 6 && Quickshell.env("HP_OS_PREVIEW_NET") === "eap") Qt.callLater(() => app.chooseNetwork({ ssid: "HP Corporate", secure: true, kind: "eap", enterprise: true }))
            if (app.step === 6 && Quickshell.env("HP_OS_PREVIEW_NET") === "hidden") Qt.callLater(() => app.chooseNetwork({ ssid: "", hidden: true, kind: "psk", secure: true }))
        }
    }

    FontLoader { source: app.themeDir + "fonts/HarmonyOS_Sans.ttf" }

    FloatingWindow {
        id: win
        visible: true
        title: app.resetMode ? "Reset password" : app.newKeyMode ? "Recovery key" : "Add user"
        color: "black"
        implicitWidth: app.newKeyMode ? 1120 : 1440
        implicitHeight: app.newKeyMode ? 820 : 900
        readonly property real d: Math.max(0.75, Math.min(2.2, Math.min(height / 1000, width / 1500)))
        function px(n) { return Math.round(n * d) }
        // Where a screen's content starts: about a third of the way down, but higher for a tall screen, so the glass
        // always ends above the dots at the bottom; never above the very top.
        function topFor(contentHeight) {
            const height = win.contentItem.height, pad = win.px(46)
            return Math.round(Math.max(pad + win.px(20), Math.min(height * 0.36, height - contentHeight - pad - win.px(76))))
        }
        readonly property real cardContent: card.holder ? card.holder.height : win.px(260)

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
            opacity: (current ? 1 : 0) * app.appear
            scale: 0.97 + 0.03 * app.appear
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            transform: Translate {
                x: page.current ? 0 : (app.order(app.step) > app.order(page.index) ? -win.px(70) : win.px(70))
                Behavior on x { NumberAnimation { duration: 480; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
            }
            readonly property Item holderItem: holder
            onCurrentChanged: if (page.current) app.activePage = page
            Component.onCompleted: if (page.current) app.activePage = page
            Column {
                id: holder
                anchors.horizontalCenter: parent.horizontalCenter
                y: win.topFor(holder.height)
                spacing: win.px(14)
                Behavior on y { NumberAnimation { duration: 560; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
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
        // A small white line drawing: qr, key, usb, done, or a turning arc for busy.
        component Glyph: Canvas {
            id: glyph
            property string shape: ""
            width: win.px(20); height: width
            onShapeChanged: { if (glyph.shape !== "busy") glyph.rotation = 0; requestPaint() }
            RotationAnimation on rotation { running: glyph.shape === "busy"; loops: Animation.Infinite; from: 0; to: 360; duration: 900 }
            onPaint: {
                const c = getContext("2d"), w = width, u = w / 20
                c.reset()
                c.strokeStyle = "white"; c.fillStyle = "white"
                c.lineWidth = Math.max(1.2, 1.8 * u); c.lineCap = "round"; c.lineJoin = "round"
                if (glyph.shape === "qr") {
                    for (const [x, y] of [[2, 2], [12, 2], [2, 12]]) { c.beginPath(); c.roundedRect(x * u, y * u, 6 * u, 6 * u, 1.4 * u, 1.4 * u); c.stroke() }
                    for (const [x, y] of [[12.5, 12.5], [16, 16], [12.5, 16.5], [16.5, 12.5]]) c.fillRect(x * u, y * u, 2.2 * u, 2.2 * u)
                } else if (glyph.shape === "key") {
                    c.beginPath(); c.arc(6.5 * u, 10 * u, 4 * u, 0, 2 * Math.PI); c.stroke()
                    c.beginPath(); c.moveTo(10.5 * u, 10 * u); c.lineTo(18 * u, 10 * u); c.moveTo(15 * u, 10 * u); c.lineTo(15 * u, 13.5 * u)
                    c.moveTo(18 * u, 10 * u); c.lineTo(18 * u, 13 * u); c.stroke()
                } else if (glyph.shape === "usb") {
                    c.beginPath(); c.moveTo(10 * u, 2.5 * u); c.lineTo(10 * u, 13 * u); c.moveTo(5.5 * u, 8.5 * u); c.lineTo(10 * u, 13 * u)
                    c.lineTo(14.5 * u, 8.5 * u); c.moveTo(3.5 * u, 17.5 * u); c.lineTo(16.5 * u, 17.5 * u); c.stroke()
                } else if (glyph.shape === "done") {
                    c.beginPath(); c.moveTo(4 * u, 10.5 * u); c.lineTo(8.5 * u, 15 * u); c.lineTo(16.5 * u, 5.5 * u); c.stroke()
                } else if (glyph.shape === "busy") {
                    c.beginPath(); c.arc(10 * u, 10 * u, 7 * u, -Math.PI / 2, Math.PI); c.stroke()
                }
            }
        }
        // A see-through pill with a glyph, like the rows in the Wi-Fi and time zone lists.
        component Tool: Rectangle {
            id: tool
            property string label: ""
            property string shape: ""
            property bool busy: false
            signal activated()
            width: toolRow.implicitWidth + win.px(48); height: win.px(50)
            radius: height / 2
            color: Qt.rgba(1, 1, 1, toolHit.pressed ? 0.24 : toolHit.containsMouse && !tool.busy ? 0.18 : 0.12)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.2)
            Behavior on color { ColorAnimation { duration: 140 } }
            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            Row {
                id: toolRow
                anchors.centerIn: parent
                spacing: win.px(10)
                Glyph { anchors.verticalCenter: parent.verticalCenter; shape: tool.busy ? "busy" : tool.shape }
                Label { anchors.verticalCenter: parent.verticalCenter; text: tool.label; font.pixelSize: win.px(17); font.weight: Font.Medium }
            }
            MouseArea { id: toolHit; anchors.fill: parent; hoverEnabled: true; enabled: !tool.busy; cursorShape: Qt.PointingHandCursor; onClicked: tool.activated() }
        }
        component Note: Label {
            anchors.horizontalCenter: parent.horizontalCenter
            width: win.px(520)
            height: win.px(26)
            wrapMode: Text.WordWrap
            font.pixelSize: win.px(16); font.weight: Font.Medium
        }

        // ── The picture, out of focus, like the login screen behind this ──
        // Larger than the screen, so the blur's soft outer edge stays out of sight.
        Rectangle { anchors.fill: parent; color: "black" }
        Item {
            id: backdropLayer
            anchors.fill: parent
            opacity: app.appear
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
                saturation: 0.12
            }
            // A plain dim, like the login screen at night: no colour of its own.
            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.30) }
        }
        // What the glass sees: the same picture, frosted further and lifted a little, like HP-OS's thick glass.
        Item {
            id: frostLayer
            anchors.fill: parent
            visible: false
            MultiEffect {
                anchors.fill: parent
                source: backdropLayer
                blurEnabled: true; blur: 1; blurMax: 48
                saturation: 0.18
                brightness: 0.05
            }
        }
        ShaderEffectSource {
            id: backdropTexture
            anchors.fill: parent
            sourceItem: frostLayer
            live: true
            visible: false
        }

        // ── One pane of glass holding each screen: it changes size smoothly from one screen to the next ──
        GlassShape {
            id: card
            readonly property Item holder: app.activePage ? app.activePage.holderItem : null
            readonly property real pad: win.px(46)
            width: card.holder ? Math.max(win.px(660), card.holder.width + 2 * card.pad) : win.px(660)
            height: card.holder ? card.holder.height + 2 * card.pad : win.px(260)
            x: Math.round((win.contentItem.width - card.width) / 2)
            y: win.topFor(win.cardContent) - card.pad
            Behavior on y { NumberAnimation { duration: 560; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
            opacity: app.appear
            scale: 0.97 + 0.03 * app.appear
            radius: win.px(44)
            d: win.d
            frost: 1
            backdropItem: backdropTexture
            hostItem: win.contentItem
            Behavior on width { NumberAnimation { duration: 560; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
            Behavior on height { NumberAnimation { duration: 560; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
        }

        // ── Who this is becoming: stays on screen through every step ──
        LoginAvatar {
            id: avatar
            visible: app.step !== 5 && app.step !== 6 && app.step !== 7 && app.step !== 13
            // Above the glass; it steps aside when a tall screen needs the room.
            readonly property real room: win.topFor(win.cardContent) - win.px(46) - win.px(22)
            opacity: app.appear * (avatar.room - win.px(16) >= avatar.width ? 1 : 0)
            Behavior on opacity { NumberAnimation { duration: 240 } }
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(Math.max(win.px(16), Math.min(parent.height * 0.17, avatar.room - avatar.width)))
            Behavior on y { NumberAnimation { duration: 560; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
            width: win.px(app.step === 4 ? 132 : 112); height: width
            icon: app.recoveryMode ? "" : app.faceUrl(app.face)
            account: app.recoveryLogin
            name: app.fullName.trim() || " "
            fontFamily: "HarmonyOS Sans"
            Behavior on width { NumberAnimation { duration: 520; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
        }

        // ── Hello: only on a new device ──
        Page {
            index: 5
            Gap { size: 20 }
            Title { text: "Hello" }
            Subtitle { text: "Let’s get your device ready. It only takes a few minutes." }
            Gap { size: 26 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Get started"
                onActivated: app.startWifi()
            }
        }

        // ── Wi-Fi (a new device) ──
        Page {
            index: 6
            Title { text: "Connect to Wi-Fi" }
            Subtitle {
                text: !app.chosenNetwork ? "HP-OS checks for the latest version before you start."
                    : app.chosenNetwork.hidden ? "Type the network’s name, and its password if it has one."
                    : app.chosenNetwork.kind === "eap" ? "Sign in to " + app.chosenNetwork.ssid + " with your username and password."
                    : app.needsNothing(app.chosenNetwork) ? "Joining " + app.chosenNetwork.ssid + "…"
                    : "Enter the password for " + app.chosenNetwork.ssid + "."
            }
            Gap { size: 12 }
            Column {
                visible: !app.chosenNetwork
                anchors.horizontalCenter: parent.horizontalCenter
                width: win.px(440)
                spacing: win.px(8)
                Label {
                    visible: app.networks.length === 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: app.scanning ? "Looking for networks…" : "No networks found."
                    color: Qt.rgba(1, 1, 1, 0.7)
                    font.pixelSize: win.px(17)
                }
                Repeater {
                    model: app.networks.slice(0, 6)
                    delegate: Rectangle {
                        id: network
                        required property var modelData
                        width: parent.width; height: win.px(54)
                        radius: height / 2
                        color: Qt.rgba(1, 1, 1, rowHit.pressed ? 0.24 : rowHit.containsMouse ? 0.18 : 0.12)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.2)
                        Behavior on color { ColorAnimation { duration: 140 } }
                        Label {
                            anchors { left: parent.left; leftMargin: win.px(26); right: bars.left; rightMargin: win.px(12); verticalCenter: parent.verticalCenter }
                            horizontalAlignment: Text.AlignLeft
                            elide: Text.ElideRight
                            text: network.modelData.ssid + (network.modelData.kind === "eap" ? "  ·  Username"
                                : !network.modelData.secure ? "  ·  Open" : "")
                            font.pixelSize: win.px(18); font.weight: Font.Medium
                        }
                        Row {
                            id: bars
                            anchors { right: parent.right; rightMargin: win.px(26); verticalCenter: parent.verticalCenter }
                            spacing: win.px(3)
                            Repeater {
                                model: 4
                                Rectangle {
                                    required property int index
                                    anchors.bottom: parent.bottom
                                    width: win.px(4); height: win.px(6 + index * 4); radius: width / 2
                                    color: Qt.rgba(1, 1, 1, network.modelData.signal >= [1, 35, 55, 75][index] ? 0.95 : 0.3)
                                }
                            }
                        }
                        MouseArea {
                            id: rowHit
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: app.chooseNetwork(network.modelData)
                        }
                    }
                }
                // A hidden network doesn't appear in the list: join it by its name.
                Rectangle {
                    visible: !app.scanning
                    width: parent.width; height: win.px(54)
                    radius: height / 2
                    color: Qt.rgba(1, 1, 1, otherHit.pressed ? 0.24 : otherHit.containsMouse ? 0.18 : 0.08)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, 0.16)
                    Label {
                        anchors { left: parent.left; leftMargin: win.px(26); verticalCenter: parent.verticalCenter }
                        text: "Other network…"
                        color: Qt.rgba(1, 1, 1, 0.85)
                        font.pixelSize: win.px(18); font.weight: Font.Medium
                    }
                    MouseArea {
                        id: otherHit
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: app.chooseNetwork({ ssid: "", hidden: true, kind: "psk", secure: true })
                    }
                }
            }
            Field {
                id: wifiName
                visible: !!app.chosenNetwork && !!app.chosenNetwork.hidden
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Network name"
                input.maximumLength: 32
                onAccepted: wifiPassword.input.forceActiveFocus()
            }
            Field {
                id: wifiUser
                visible: !!app.chosenNetwork && app.chosenNetwork.kind === "eap"
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Username"
                input.maximumLength: 128
                input.inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                onAccepted: wifiPassword.input.forceActiveFocus()
            }
            Field {
                id: wifiPassword
                visible: !!app.chosenNetwork && !app.needsNothing(app.chosenNetwork)
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: app.chosenNetwork && app.chosenNetwork.hidden ? "Password (if it has one)"
                    : app.chosenNetwork && app.chosenNetwork.kind === "eap" ? "Password" : "Wi-Fi password"
                secret: true
                failed: app.wifiNotice.length > 0
                input.maximumLength: 256
                onAccepted: app.joinWifi()
            }
            // A network with a password says "Joining…" on its Join button; an open one has no button, so it says it here.
            Note { color: app.wifiNotice ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.8); text: app.joining ? (app.needsNothing(app.chosenNetwork) ? "Joining…" : " ") : app.wifiNotice || " " }
            Primary {
                visible: !!app.chosenNetwork && !app.needsNothing(app.chosenNetwork)
                anchors.horizontalCenter: parent.horizontalCenter
                label: app.joining ? "Joining…" : "Join"
                ready: app.wifiReady
                onActivated: app.joinWifi()
            }
            Quiet {
                anchors.horizontalCenter: parent.horizontalCenter
                text: app.chosenNetwork ? "Other networks" : app.scanning ? " " : "Look again"
                onActivated: { if (app.chosenNetwork) { app.chosenNetwork = null; wifiPassword.text = ""; wifiUser.text = ""; wifiName.text = ""; app.wifiNotice = "" } else app.scanWifi() }
            }
            Gap { size: 4 }
            Quiet {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Set up without Wi-Fi"
                onActivated: app.skipWifi()
            }
        }

        // ── Wi-Fi that wants a web sign-in first ──
        Page {
            index: 13
            Title { text: app.netState === "portal" ? "Sign in to Wi-Fi" : "No internet yet" }
            Subtitle {
                text: app.netState === "portal"
                    ? (app.signInNetwork || "This network") + " asks you to sign in or accept its terms on a web page before HP-OS can check for updates."
                    : "You’re connected to " + (app.signInNetwork || "this network") + ", but it isn’t reaching the internet. Setup carries on by itself once it does."
            }
            Gap { size: 18 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: app.netState === "portal" ? (app.signInOpen ? (app.signInShown ? "Show sign-in page" : "Opening…") : "Open sign-in page")
                    : app.checkingNet ? "Checking…" : "Try again"
                ready: app.netState === "portal" ? (!app.signInOpen || app.signInShown) : !app.checkingNet
                onActivated: app.netState === "portal" ? app.openSignIn() : app.checkInternet()
            }
            Note {
                color: app.signInNotice.length > 0 ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.8)
                text: app.signInNotice.length > 0 ? app.signInNotice
                    : app.netState !== "portal" ? "Checking again every few seconds."
                    : app.signInOpen && !app.signInShown ? "Opening the sign-in page…"
                    : app.signInOpen ? "It closes by itself once you’re online. Press Ctrl+W to come back."
                    : "Once you’re signed in, setup carries on by itself."
            }
            // A sign-in page the checks didn't spot: open one anyway.
            Quiet {
                visible: app.netState !== "portal"
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Open a sign-in page"
                onActivated: { app.netState = "portal"; app.openSignIn() }
            }
            Gap { size: 4 }
            Quiet { anchors.horizontalCenter: parent.horizontalCenter; text: "Choose another network"; onActivated: app.leaveSignIn(true) }
            Gap { size: 4 }
            Quiet { anchors.horizontalCenter: parent.horizontalCenter; text: "Set up without Wi-Fi"; onActivated: app.leaveSignIn(false) }
        }

        // ── Software update (a new device) ──
        Page {
            index: 7
            Title {
                text: app.updatePhase === "installing" ? "Updating HP-OS"
                    : app.updatePhase === "restarting" ? "Restarting"
                    : app.updatePhase === "current" ? "HP-OS is up to date"
                    : app.updatePhase === "failed" ? "Update not installed" : "Checking for updates"
            }
            Subtitle {
                text: app.updatePhase === "installing" ? "Getting HP-OS " + app.updateVersion + " ready"
                        + (app.updateBytes > 0 ? ": a " + app.sizeText(app.updateBytes) + " download" : "")
                        + (app.updateEstimate > 0 ? " that takes " + app.durationText(app.updateEstimate) + " on this connection" : "")
                        + ". Please keep your device plugged in."
                    : app.updatePhase === "restarting" ? "Your device restarts to finish, then continues setup."
                    : app.updatePhase === "current" ? "You’re on the latest version."
                    : app.updatePhase === "failed" ? app.updateMessage : "Seeing what’s new and how big it is. This can take a minute."
            }
            Gap { size: 22 }
            Rectangle {
                visible: app.updatePhase === "installing" || app.updatePhase === "checking"
                anchors.horizontalCenter: parent.horizontalCenter
                width: win.px(400); height: win.px(6); radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.2)
                clip: true
                Rectangle {
                    id: updateBar
                    height: parent.height; radius: height / 2
                    color: "white"
                    width: app.updatePhase === "installing" ? Math.max(parent.width * 0.04, parent.width * app.updateProgress / 100) : parent.width * 0.3
                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                    // While checking, a short bar sweeps back and forth.
                    SequentialAnimation on x {
                        running: app.updatePhase === "checking"
                        loops: Animation.Infinite
                        NumberAnimation { from: 0; to: win.px(400) * 0.7; duration: 900; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: win.px(400) * 0.7; to: 0; duration: 900; easing.type: Easing.InOutQuad }
                    }
                    onWidthChanged: if (app.updatePhase === "installing") x = 0
                }
            }
            Note {
                visible: app.updatePhase === "installing"
                color: Qt.rgba(1, 1, 1, 0.75)
                text: app.updateLeft.length > 0 ? app.updateLeft + " · " + app.updateMessage : app.updateMessage
            }
            Primary {
                visible: app.updatePhase === "failed"
                anchors.horizontalCenter: parent.horizontalCenter
                label: "Continue"
                onActivated: app.skipWifi()
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
                onActivated: { if (app.firstBoot) app.step = app.online ? 5 : 6; else app.leave("", "") }
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
                if (app.firstBoot) app.showRecoveryKey(password)
                else app.requestAccount(password)
            }
        }

        // ── 4. Time zone (a new device) ──
        Page {
            index: 8
            Title { text: "Choose your time zone" }
            Subtitle { text: "Search for your country or a city." }
            Gap { size: 14 }
            Field {
                id: zoneSearchField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Search"
                input.maximumLength: 48
                input.onTextChanged: {
                    app.zoneSearch = zoneSearchField.text
                    // The best match is chosen as you type, so Enter takes it.
                    if (app.zoneSearch.trim().length > 0 && app.zoneMatches.length > 0) {
                        app.chosenZone = app.zoneMatches[0].zone
                        zoneList.positionViewAtBeginning()
                    }
                }
                onAccepted: { if (app.chosenZone) app.confirmTimeZone() }
                Keys.onDownPressed: zoneList.move(1)
                Keys.onUpPressed: zoneList.move(-1)
            }
            ListView {
                id: zoneList
                anchors.horizontalCenter: parent.horizontalCenter
                width: win.px(440)
                height: win.px(4 * 50 + 3 * 6)
                spacing: win.px(6)
                clip: true
                // Free, phone-like scrolling: a flick carries on and slows gently, and the ends give a little.
                boundsBehavior: Flickable.DragAndOvershootBounds
                flickDeceleration: win.px(900)
                maximumFlickVelocity: win.px(7000)
                pixelAligned: true
                model: app.zoneMatches
                function move(by) {
                    const places = app.zoneMatches
                    if (places.length === 0) return
                    const at = places.findIndex(place => place.zone === app.chosenZone)
                    const next = Math.max(0, Math.min(places.length - 1, at < 0 ? 0 : at + by))
                    app.chosenZone = places[next].zone
                    zoneList.positionViewAtIndex(next, ListView.Contain)
                }
                Connections {
                    target: app
                    function onStepChanged() { if (app.step === 8) Qt.callLater(zoneList.showChosen) }
                    function onZonesChanged() { Qt.callLater(zoneList.showChosen) }
                }
                function showChosen() {
                    const at = app.zoneMatches.findIndex(place => place.zone === app.chosenZone)
                    if (at >= 0) zoneList.positionViewAtIndex(at, ListView.Center)
                }
                delegate: Rectangle {
                    id: zoneRow
                    required property var modelData
                    readonly property bool chosen: modelData.zone === app.chosenZone
                    width: zoneList.width; height: win.px(50)
                    radius: height / 2
                    color: chosen ? "white" : Qt.rgba(1, 1, 1, zoneHit.pressed ? 0.24 : zoneHit.containsMouse ? 0.18 : 0.12)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, chosen ? 0 : 0.2)
                    Behavior on color { ColorAnimation { duration: 140 } }
                    Column {
                        anchors { left: parent.left; leftMargin: win.px(24); right: zoneOffset.left; rightMargin: win.px(12); verticalCenter: parent.verticalCenter }
                        Label {
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                            elide: Text.ElideRight
                            text: app.placeName(zoneRow.modelData)
                            color: zoneRow.chosen ? "#0b2a6b" : "white"
                            font.pixelSize: win.px(17); font.weight: Font.Medium
                        }
                        Label {
                            visible: zoneRow.modelData.region.length > 0
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                            elide: Text.ElideRight
                            text: zoneRow.modelData.region
                            color: zoneRow.chosen ? Qt.rgba(0.04, 0.16, 0.42, 0.7) : Qt.rgba(1, 1, 1, 0.65)
                            font.pixelSize: win.px(13)
                        }
                    }
                    Label {
                        id: zoneOffset
                        anchors { right: parent.right; rightMargin: win.px(24); verticalCenter: parent.verticalCenter }
                        text: app.offsetText(zoneRow.modelData.offset)
                        color: zoneRow.chosen ? "#0b2a6b" : Qt.rgba(1, 1, 1, 0.75)
                        font.pixelSize: win.px(15)
                    }
                    MouseArea {
                        id: zoneHit
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { app.chosenZone = zoneRow.modelData.zone; zoneSearchField.input.forceActiveFocus() }
                        onDoubleClicked: app.confirmTimeZone()
                    }
                }
                Label {
                    visible: zoneList.count === 0
                    anchors.centerIn: parent
                    text: app.zones.length === 0 && !app.zoneNotice ? "Loading…" : app.zones.length === 0 ? "" : "No places match that."
                    color: Qt.rgba(1, 1, 1, 0.7)
                    font.pixelSize: win.px(17)
                }
            }
            Note {
                color: app.zoneNotice ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.8)
                text: app.zoneNotice ? app.zoneNotice
                    : app.chosenPlace ? "It’s " + app.timeThere(app.chosenPlace.offset) + " in " + app.chosenPlace.city + "." : " "
            }
            Gap { size: 4 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: app.settingZone ? "Setting…" : "Continue"
                ready: !app.settingZone && (!!app.chosenZone || (app.zones.length === 0 && app.zoneNotice.length > 0))
                onActivated: app.confirmTimeZone()
            }
            Quiet { anchors.horizontalCenter: parent.horizontalCenter; text: "Back"; onActivated: app.leaveTimeZone() }
        }

        // ── The recovery key: once on a new device, or a new one from Settings ──
        Page {
            index: 9
            Title { text: app.newKeyMode ? "Your new recovery key" : "Save your recovery key" }
            Subtitle {
                text: app.newKeyMode ? "Your old key no longer works. If you forget your password, this one lets you set a new one."
                    : "If you forget your password, this key lets you set a new one and keep all your files."
            }
            Gap { size: 14 }
            Rectangle {
                id: keyCard
                anchors.horizontalCenter: parent.horizontalCenter
                width: win.px(440)
                height: app.showQr ? win.px(222) : win.px(106)
                radius: app.showQr ? win.px(30) : height / 2
                color: "white"
                Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.BezierSpline; easing.bezierCurve: app.expressive } }
                Behavior on radius { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                Label {
                    anchors.centerIn: parent
                    opacity: app.showQr ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    text: app.recoveryKey.slice(0, 14) + "\n" + app.recoveryKey.slice(15)
                    color: "#0b2a6b"
                    font.pixelSize: win.px(28); font.weight: Font.Medium; font.letterSpacing: win.px(2)
                    lineHeight: 1.25
                }
                Canvas {
                    id: qrCanvas
                    anchors.centerIn: parent
                    width: win.px(184); height: width
                    opacity: app.showQr ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    Connections { target: app; function onRecoveryQrChanged() { qrCanvas.requestPaint() } }
                    onWidthChanged: requestPaint()
                    onPaint: {
                        const c = getContext("2d"), rows = app.recoveryQr
                        c.reset()
                        if (rows.length === 0) return
                        const cell = Math.floor(width / rows.length), offset = Math.floor((width - cell * rows.length) / 2)
                        c.fillStyle = "#0b2a6b"
                        for (let y = 0; y < rows.length; y++)
                            for (let x = 0; x < rows[y].length; x++)
                                if (rows[y].charAt(x) === "1") c.fillRect(offset + x * cell, offset + y * cell, cell, cell)
                    }
                }
            }
            Gap { size: 2 }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: win.px(12)
                Tool {
                    visible: app.recoveryQr.length > 0
                    shape: app.showQr ? "key" : "qr"
                    label: app.showQr ? "Show the key" : "Show QR code"
                    onActivated: app.showQr = !app.showQr
                }
                Tool {
                    shape: app.usbState === "saved" ? "done" : "usb"
                    busy: app.usbState === "saving"
                    label: app.usbState === "saving" ? "Saving…" : app.usbState === "saved" ? "Saved" : "Save to USB stick"
                    onActivated: app.saveToUsb()
                }
            }
            Note {
                color: app.usbState === "failed" ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.8)
                text: app.usbMessage.length > 0 ? app.usbMessage
                    : app.showQr ? "Point your phone’s camera here to save the key on your phone."
                    : "Keep it away from this laptop. You won’t see it again here."
            }
            Gap { size: 4 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: "I’ve saved it"
                ready: app.usbState !== "saving"
                onActivated: app.recoveryKeySaved()
            }
            Quiet {
                visible: app.firstBoot
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Back"
                onActivated: { app.heldPassword = ""; app.step = 2; passwordField.input.forceActiveFocus() }
            }
        }

        // ── Forgot password: a new one with the recovery key (opened from the login screen) ──
        Page {
            index: 10
            Title { text: "Reset your password" }
            Subtitle { text: "Type the recovery key you saved when this device was set up, then choose a new password." }
            Gap { size: 14 }
            Field {
                id: keyField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Recovery key"
                input.maximumLength: 40
                input.font.capitalization: Font.AllUppercase
                input.inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhPreferUppercase
                input.onTextChanged: app.recoveryNotice = ""
                onAccepted: newPasswordField.input.forceActiveFocus()
            }
            Field {
                id: newPasswordField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "New password"; secret: true
                input.maximumLength: 256
                onAccepted: againField.input.forceActiveFocus()
            }
            Field {
                id: againField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Verify new password"; secret: true
                failed: resetPage.mismatch
                input.maximumLength: 256
                onAccepted: resetPage.go()
            }
            Note {
                color: app.recoveryNotice.length > 0 || resetPage.mismatch ? "#ffb4ab" : Qt.rgba(1, 1, 1, 0.72)
                text: app.recoveryNotice.length > 0 ? app.recoveryNotice
                    : resetPage.mismatch ? "Those passwords don’t match."
                    : "Use at least 8 characters."
            }
            Gap { size: 8 }
            Primary {
                anchors.horizontalCenter: parent.horizontalCenter
                label: app.recoveryBusy ? "Checking…" : "Reset password"
                ready: resetPage.ready
                onActivated: resetPage.go()
            }
            Quiet { anchors.horizontalCenter: parent.horizontalCenter; text: "Cancel"; onActivated: if (!app.recoveryBusy) Qt.quit() }
        }
        QtObject {
            id: resetPage
            readonly property bool mismatch: againField.text.length > 0 && againField.text !== newPasswordField.text
            readonly property bool ready: !app.recoveryBusy && keyField.text.replace(/[^A-Za-z0-9]/g, "").length === 24
                && newPasswordField.text.length >= 8 && againField.text === newPasswordField.text
            function go() {
                if (!ready) return
                const key = keyField.text, password = newPasswordField.text
                newPasswordField.text = ""; againField.text = ""
                app.resetPassword(key, password)
            }
        }
        Page {
            index: 11
            Title { text: "Your password is reset" }
            Subtitle { text: "Sign in with your new password. An app that saved passwords may ask for your old one once." }
            Gap { size: 22 }
            Primary { anchors.horizontalCenter: parent.horizontalCenter; label: "Back to sign in"; onActivated: Qt.quit() }
        }

        // ── A new recovery key (opened from Settings): the administrator's own password first ──
        Page {
            index: 12
            Title { text: "Make a new recovery key" }
            Subtitle { text: "Your old key will stop working. Type your password to continue." }
            Gap { size: 14 }
            Field {
                id: ownPasswordField
                anchors.horizontalCenter: parent.horizontalCenter
                placeholder: "Your password"; secret: true
                failed: app.recoveryNotice.length > 0
                input.maximumLength: 256
                input.onTextChanged: if (ownPasswordField.text.length > 0) app.recoveryNotice = ""
                onAccepted: newKeyPage.go()
            }
            Note { color: "#ffb4ab"; text: app.recoveryNotice.length > 0 ? app.recoveryNotice : " " }
            Gap { size: 8 }
            Primary {
                id: newKeyPage
                anchors.horizontalCenter: parent.horizontalCenter
                label: app.recoveryBusy ? "Checking…" : "Continue"
                ready: !app.recoveryBusy && ownPasswordField.text.length > 0
                function go() {
                    if (!ready) return
                    const password = ownPasswordField.text
                    ownPasswordField.text = ""
                    app.makeNewKey(password)
                }
                onActivated: go()
            }
            Quiet { anchors.horizontalCenter: parent.horizontalCenter; text: "Cancel"; onActivated: if (!app.recoveryBusy) Qt.quit() }
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

        // Where you are: four quiet dots (name, picture, password, then approval or the time zone).
        Row {
            readonly property int at: app.step === 8 || app.step === 9 ? 3 : app.step
            visible: !app.recoveryMode && (app.firstBoot ? (app.step < 3 || app.step === 8 || app.step === 9) : app.step < 4)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: win.px(46)
            spacing: win.px(10)
            Repeater {
                model: 4
                Rectangle {
                    required property int index
                    width: win.px(index === parent.at ? 22 : 8); height: win.px(8)
                    radius: height / 2
                    color: Qt.rgba(1, 1, 1, index === parent.at ? 0.95 : 0.4)
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
            enabled: app.step === 4 || app.step === 1 || app.step === 5 || app.step === 11
            onActivated: {
                if (app.step === 11) Qt.quit()
                else if (app.step === 5) app.startWifi()
                else if (app.step === 4) app.continueToDesktop()
                else { app.step = 2; passwordField.input.forceActiveFocus() }
            }
        }
        Shortcut { sequence: "Left"; enabled: app.step === 1; onActivated: app.moveFace(-1) }
        Shortcut { sequence: "Right"; enabled: app.step === 1; onActivated: app.moveFace(1) }
        Shortcut {
            sequence: "Escape"
            onActivated: {
                if (app.step === 6 && app.chosenNetwork && !app.joining) { app.chosenNetwork = null; app.wifiNotice = "" }
                else if (app.step === 0 && app.firstBoot) app.step = 5
                else if (app.step === 0) app.leave("", "")
                else if (app.step === 1) { app.step = 0; nameField.input.forceActiveFocus() }
                else if (app.step === 2) { app.step = 1; win.contentItem.forceActiveFocus() }
                else if (app.step === 8 && !app.settingZone) app.leaveTimeZone()
                else if (app.step === 13) app.leaveSignIn(true)
                else if (app.step === 9 && app.firstBoot) { app.heldPassword = ""; app.step = 2; passwordField.input.forceActiveFocus() }
                else if (app.recoveryMode && !app.recoveryBusy) Qt.quit()
                else if (app.step === 3 && !app.working) app.cancelApproval()
            }
        }
    }
}

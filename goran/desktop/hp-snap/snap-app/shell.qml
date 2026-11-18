// hp-snap: window snapping for niri (HP-OS). Platform glue around SnapEngine:
// niri sockets, per-screen work-area probes, the command socket used by key
// bindings, and the live settings file. Logic lives in lib/*.mjs.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "lib/engine.mjs" as Eng
import "lib/layouts.mjs" as Layouts
import "lib/picker.mjs" as Picker

ShellRoot {
    id: root

    readonly property string niriSocket: Quickshell.env("NIRI_SOCKET")
    // HP_SNAP_SOCKET lets a test instance (e.g. inside a nested niri) use its own socket.
    readonly property string commandSocket: Quickshell.env("HP_SNAP_SOCKET")
        || (Quickshell.env("XDG_RUNTIME_DIR") + "/hp-snap.sock")
    readonly property string settingsPath: Quickshell.env("HOME") + "/.config/hp-snap/settings.json"
    property var engine: null
    property var settings: Eng.DEFAULT_SETTINGS

    signal engineEvent(string name, var data)

    Component.onCompleted: {
        engine = new Eng.SnapEngine({
            send: obj => requests.send(obj),
            now: () => Date.now(),
            schedule: (ms, fn) => root.schedule(ms, fn),
            log: (...args) => console.info("hp-snap:", ...args),
            emit: (name, data) => {
                if (name === "settings") root.settings = data
                root.engineEvent(name, data)
            },
        })
        outputsProc.running = true
    }

    // ---- timers for the engine -------------------------------------------------

    Component {
        id: timerComponent
        Timer { repeat: false }
    }

    function schedule(ms, fn) {
        const t = timerComponent.createObject(root, { interval: Math.max(1, Math.round(ms)) })
        t.triggered.connect(() => {
            try { fn() } catch (e) { console.warn("hp-snap: timer callback failed:", e, e.stack) }
            t.destroy()
        })
        t.start()
    }

    // ---- niri sockets -------------------------------------------------------------

    Socket {
        id: events
        path: root.niriSocket
        connected: true
        onConnectionStateChanged: {
            if (connected) {
                write('"EventStream"\n')
                flush()
            } else {
                reconnect.restart()
            }
        }
        parser: SplitParser {
            onRead: line => {
                let ev
                try { ev = JSON.parse(line) } catch (e) { return }
                if (ev.Ok !== undefined || ev.Err !== undefined || !root.engine) return
                try {
                    root.engine.handleEvent(ev)
                    // Output positions come from the config (Displays settings): re-read them then too.
                    if (ev.WorkspacesChanged || ev.ConfigLoaded) outputsProc.running = true
                } catch (e) {
                    console.warn("hp-snap: event failed:", e, e.stack)
                }
            }
        }
    }

    Socket {
        id: requests
        path: root.niriSocket
        connected: true
        onConnectionStateChanged: if (!connected) reconnect.restart()
        parser: SplitParser {
            onRead: line => {
                if (line.indexOf('"Err"') >= 0) console.warn("hp-snap: niri refused a request:", line)
            }
        }
        function send(obj) {
            if (!connected) return
            write(JSON.stringify(obj) + "\n")
            flush()
        }
    }

    Timer {
        id: reconnect
        interval: 1000
        onTriggered: {
            if (!events.connected) events.connected = true
            if (!requests.connected) requests.connected = true
        }
    }

    Process {
        id: outputsProc
        command: ["niri", "msg", "--json", "outputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.engine.setOutputs(JSON.parse(text)) } catch (e) { console.warn("hp-snap: outputs:", e) }
            }
        }
    }

    // ---- work-area probes: a transparent, input-less layer surface per screen
    // that respects other surfaces' exclusive zones, so its size is the work area.

    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Normal
            color: "transparent"
            mask: Region {}
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "hp-snap-workarea"
            function report() {
                if (root.engine && width > 0 && height > 0) root.engine.setWorkArea(modelData.name, width, height)
            }
            onWidthChanged: report()
            onHeightChanged: report()
            Component.onCompleted: Qt.callLater(report)
        }
    }

    // ---- command socket for key bindings (`hp-snap key left`, `hp-snap state`) ----

    SocketServer {
        active: true
        path: root.commandSocket
        handler: Socket {
            id: client
            parser: SplitParser {
                onRead: line => {
                    let reply = "ok"
                    try {
                        const result = root.handleCommand(line)
                        if (result !== undefined && result !== null && typeof result === "object")
                            reply = JSON.stringify(result)
                    } catch (e) {
                        reply = "error: " + e
                        console.warn("hp-snap: command failed:", line, e, e.stack)
                    }
                    client.write(reply + "\n")
                    client.flush()
                    client.connected = false
                }
            }
        }
    }

    function handleCommand(line) {
        const parts = String(line).trim().split(/\s+/)
        const cmd = parts[0]
        if (cmd === "reload-settings") { settingsFile.reload(); return null }
        if (cmd === "picker") return openPicker(parts[1] !== undefined ? Number(parts[1]) : engine.focusedId)
        if (cmd === "overlay") return overlayState()
        if (cmd === "overlay-key") return overlayKey(parts[1])
        if (cmd === "debug-hints") {
            // Show the drag hints for 3 s without a drag (for checking how they look).
            for (const k in overlays) overlays[k].showHints()
            schedule(3000, () => { for (const k in overlays) overlays[k].hideHints() })
            return null
        }
        return root.engine.command(line)
    }

    // ---- overlays: picker and Fill Assist ----------------------------------------

    property var overlays: ({})

    Variants {
        model: Quickshell.screens
        SnapOverlay {
            shell: root
            Component.onCompleted: root.overlays[outputName] = this
            Component.onDestruction: delete root.overlays[outputName]
        }
    }

    function overlayFor(outputName) {
        return overlays[outputName] || null
    }

    function openPicker(id) {
        if (!settings.snapEnabled || id === null || id === undefined || !engine.windows.has(id)) return null
        const ov = overlayFor(engine.outputNameOf(id))
        if (ov) ov.openPicker(id)
        return null
    }

    onEngineEvent: (name, data) => {
        if (name === "snapped" && data.instanceId && !data.quiet && settings.fillAssist) {
            const ov = overlayFor(data.output)
            if (ov && ov.mode !== "picker") ov.openFill(data.instanceId)
        } else if (name === "focus") {
            for (const k in overlays) overlays[k].onFocusChanged(data)
        } else if (name === "windows") {
            for (const k in overlays) overlays[k].refreshFill()
        } else if (name === "drag-start") {
            // Hints on every screen: the window may be dropped on any of them. With the
            // patched niri ("live") only the Windows-style preview box is shown.
            for (const k in overlays) { overlays[k].liveDrag = data.live; overlays[k].showHints() }
        } else if (name === "drag-live") {
            for (const k in overlays) overlays[k].liveDrag = true
        } else if (name === "drag-preview") {
            for (const k in overlays) overlays[k].dragPreview = data
        } else if (name === "drag-end") {
            for (const k in overlays) overlays[k].hideHints()
        } else if (name === "drag-state") {
            for (const k in overlays) {
                overlays[k].dragCancelled = data.cancelled
                overlays[k].dragSuppressed = data.suppressed
            }
        } else if (name === "resize-preview") {
            for (const k in overlays) {
                if (data && k === data.output) overlays[k].showResize(data.rects)
                else overlays[k].hideResize()
            }
        } else if (name === "open-picker") {
            openPicker(data)
        } else if (name === "settings" && !data.snapEnabled) {
            engine.endDrag()
            for (const k in overlays) overlays[k].close() // §19.20: switched off: hide everything
        }
    }

    // Debug/testing: what the overlays show, and drive them by key name.
    function overlayState() {
        const out = {}
        for (const k in overlays) {
            const o = overlays[k]
            out[k] = { mode: o.mode, layout: o.layouts[o.li] ? o.layouts[o.li].id : null, zone: o.zi,
                fill: o.fill, candidates: o.candidates.map(c => c.id), current: o.ci }
        }
        return out
    }

    function overlayKey(key) {
        for (const k in overlays) {
            const o = overlays[k]
            if (o.mode === "picker") {
                if (key === "enter") o.commitPicker()
                else if (key === "esc") o.close()
                else { const s = Picker.pickerMove(o.layouts, { li: o.li, zi: o.zi }, key); o.li = s.li; o.zi = s.zi }
            } else if (o.mode === "fill") {
                if (key === "enter") o.chooseCandidate(o.ci)
                else if (key === "esc") o.close()
                else if (key === "right") o.ci = Math.min(o.candidates.length - 1, o.ci + 1)
                else if (key === "left") o.ci = Math.max(0, o.ci - 1)
            }
        }
        return overlayState()
    }

    // ---- settings (live reload) ------------------------------------------------

    FileView {
        id: settingsFile
        path: root.settingsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.applySettings(text())
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                setText(JSON.stringify(Eng.DEFAULT_SETTINGS, null, 2) + "\n")
            }
        }
    }

    function applySettings(text) {
        let obj
        try { obj = JSON.parse(text) } catch (e) {
            console.warn("hp-snap: settings.json is not valid JSON; keeping previous settings:", e)
            return
        }
        const custom = Array.isArray(obj.customLayouts) ? obj.customLayouts : []
        obj.customLayouts = custom.filter(l => {
            const res = Layouts.validateLayout(l)
            if (!res.ok) console.warn(`hp-snap: custom layout "${l && l.name}" rejected: ${res.errors.join("; ")}`)
            for (const w of res.warnings) console.warn(`hp-snap: custom layout "${l.name}": ${w}`)
            return res.ok
        })
        root.engine.setSettings(obj)
        console.info("hp-snap: settings loaded")
    }
}


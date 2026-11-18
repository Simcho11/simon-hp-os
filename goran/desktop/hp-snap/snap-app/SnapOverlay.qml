// Per-screen overlay: the Super+Z layout picker (§7), Fill Assist (§8.2) and
// the snap preview (§15). Invisible and input-less unless one is open.
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import "lib/picker.mjs" as Picker
import "lib/layouts.mjs" as Layouts

PanelWindow {
    id: ov

    required property var modelData
    required property var shell
    readonly property string outputName: modelData.name
    readonly property var engine: shell.engine

    screen: modelData
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: mode !== ""
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "hp-snap-overlay"
    // Only the picker, Fill Assist and drag hints take the keyboard. The resize
    // outline must not: a focus change could disturb the resize it accompanies.
    WlrLayershell.keyboardFocus: mode === "picker" || mode === "fill" || mode === "hints"
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    // Hints and outlines are drawn over everything but never take the pointer.
    mask: mode === "hints" || mode === "resize" ? noInput : null
    Region { id: noInput }

    // Theme: niri's focus-ring blue on a dark surface (WCAG AA for the text).
    readonly property color accent: "#3377ff"
    readonly property color surface: "#20232b"
    readonly property color neutral: "#4a5160"
    readonly property color textColor: "#f2f4f8"
    readonly property color subtleText: "#b8bfcc"
    readonly property int animMs: shell.settings.animations ? 1 : 0

    property string mode: ""        // "", "picker", "fill", "hints" (window drag) or "resize" (border drag)
    property int targetId: -1       // picker: the window being placed
    property var layouts: []
    property int li: 0
    property int zi: 0
    property var fill: null         // engine.nextFillZone() result
    property var candidates: []
    property int ci: 0
    property var placingIds: []     // windows we just placed (their focus change isn't a dismissal)
    property var resizeRects: []    // resize mode: where neighbours will go
    property bool liveDrag: false   // patched niri: live preview instead of static hints
    property var dragPreview: null  // { output, target, rect } while a live preview shows
    property bool dragCancelled: false
    property bool dragSuppressed: false

    readonly property var previewRect: {
        if (mode === "picker" && layouts.length && layouts[li])
            return engine.zoneRectOn(outputName, layouts[li].zones[zi])
        if (mode === "fill" && fill) return fill.rect
        if (mode === "hints" && dragPreview && dragPreview.rect && dragPreview.output === outputName)
            return dragPreview.rect
        return null
    }

    // ---- drag to snap: drop-zone hints ------------------------------------------------
    // niri reports when a window drag starts and where it is dropped, but nothing in
    // between, so the drop zones are shown for the whole drag and the snap happens
    // on drop. The overlay takes the keyboard so Esc and Ctrl work mid-drag.

    function showHints() {
        if (mode === "picker" || mode === "fill") close()
        dragCancelled = false
        dragSuppressed = false
        mode = "hints"
        keyCatcher.forceActiveFocus()
    }

    function hideHints() {
        if (mode === "hints") mode = ""
        dragPreview = null
    }

    // Border drag between snapped windows: outline where the neighbours will go.
    function showResize(rects) {
        if (mode !== "" && mode !== "resize") return // don't disturb the picker or Fill Assist
        resizeRects = rects
        mode = "resize"
    }

    function hideResize() {
        if (mode === "resize") mode = ""
        resizeRects = []
    }

    // ---- opening and closing -------------------------------------------------------

    function openPicker(id) {
        layouts = engine.layoutsFor(outputName)
        if (!layouts.length) return
        targetId = id
        li = 0
        zi = 0
        fill = null
        mode = "picker"
        keyCatcher.forceActiveFocus()
    }

    function openFill(instanceId) {
        const next = engine.nextFillZone(instanceId)
        const cands = next ? engine.fillCandidates(instanceId) : []
        if (!next || !cands.length) { if (mode === "fill") close(); return }
        fill = next
        candidates = cands
        ci = 0
        mode = "fill"
        keyCatcher.forceActiveFocus()
        console.info(`hp-snap: Choose a window for the ${next.position}, ${cands.length} options`)
    }

    function refreshFill() {
        if (mode === "fill" && fill) openFill(fill.instanceId)
    }

    function close() {
        mode = ""
        fill = null
        candidates = []
        layouts = []
    }

    function commitPicker() {
        const layout = layouts[li]
        const id = targetId
        close()
        if (layout) {
            placingIds = [id]
            engine.snapToLayout(id, layout.id, zi, outputName)
        }
    }

    function chooseCandidate(i) {
        const c = candidates[i]
        if (!c || !fill) return
        const f = fill
        placingIds = [c.id]
        engine.snapToLayout(c.id, f.layoutId, f.zoneIndex, f.output)
        Qt.callLater(() => openFill(f.instanceId)) // next empty zone, fresh candidates
    }

    // Focusing a window by other means dismisses Fill Assist (never moves anything).
    function onFocusChanged(id) {
        if (mode !== "fill") return
        // null: our own overlay took keyboard focus, not the user focusing a window.
        if (id === null || id === undefined) return
        if (placingIds.indexOf(id) >= 0 || engine.isPending(id)) return
        close()
    }

    // ---- keyboard ------------------------------------------------------------------

    function keyName(event) {
        switch (event.key) {
        case Qt.Key_Left: return "left"
        case Qt.Key_Right: return "right"
        case Qt.Key_Up: return "up"
        case Qt.Key_Down: return "down"
        case Qt.Key_Tab: return "tab"
        case Qt.Key_Backtab: return "backtab"
        }
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) return String(event.key - Qt.Key_0)
        return ""
    }

    Item {
        id: keyCatcher
        focus: true
        Keys.onReleased: event => {
            if (ov.mode === "hints" && event.key === Qt.Key_Control) ov.engine.dragSuppress(false)
        }
        Keys.onPressed: event => {
            event.accepted = true
            if (ov.mode === "hints") {
                if (event.key === Qt.Key_Escape) ov.engine.dragCancel()
                else if (event.key === Qt.Key_Control) ov.engine.dragSuppress(true)
                return
            }
            if (event.key === Qt.Key_Escape) { ov.close(); return }
            const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space
            if (ov.mode === "picker") {
                if (enter) { ov.commitPicker(); return }
                const k = ov.keyName(event)
                if (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier)) {
                    const s = Picker.pickerMove(ov.layouts, { li: ov.li, zi: ov.zi }, "backtab")
                    ov.li = s.li; ov.zi = s.zi
                } else if (k) {
                    const s = Picker.pickerMove(ov.layouts, { li: ov.li, zi: ov.zi }, k)
                    ov.li = s.li; ov.zi = s.zi
                }
            } else if (ov.mode === "fill") {
                if (enter) { ov.chooseCandidate(ov.ci); return }
                const cols = Math.max(1, candidateGrid.columns)
                const step = { left: -1, right: 1, up: -cols, down: cols }[ov.keyName(event)]
                if (step) ov.ci = Math.max(0, Math.min(ov.candidates.length - 1, ov.ci + step))
            }
        }
    }

    // ---- visuals -------------------------------------------------------------------

    // Click on empty space dismisses (§7, §8.2).
    MouseArea {
        anchors.fill: parent
        enabled: ov.mode !== "hints"
        onClicked: ov.close()
    }

    Repeater {
        model: ov.mode === "resize" ? ov.resizeRects : []
        delegate: Rectangle {
            required property var modelData
            x: modelData.x + 4
            y: modelData.y + 4
            width: modelData.w - 8
            height: modelData.h - 8
            radius: 10
            color: Qt.rgba(ov.accent.r, ov.accent.g, ov.accent.b, 0.12)
            border.width: 3
            border.color: Qt.rgba(ov.accent.r, ov.accent.g, ov.accent.b, 0.8)
        }
    }

    DropHints {
        anchors.fill: parent
        visible: ov.mode === "hints" && !ov.liveDrag
        overlay: ov
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: ov.mode === "fill" ? 0.2 : 0
        Behavior on opacity { NumberAnimation { duration: 80 * ov.animMs } }
    }

    // Preview of where the window will land.
    Rectangle {
        id: preview
        visible: ov.previewRect !== null && (ov.mode === "picker" || ov.mode === "hints")
        x: ov.previewRect ? ov.previewRect.x : 0
        y: ov.previewRect ? ov.previewRect.y : 0
        width: ov.previewRect ? ov.previewRect.w : 0
        height: ov.previewRect ? ov.previewRect.h : 0
        radius: 8
        color: Qt.rgba(ov.accent.r, ov.accent.g, ov.accent.b, 0.25)
        border.width: 2
        border.color: Qt.rgba(ov.accent.r, ov.accent.g, ov.accent.b, 0.6)
        Behavior on x { NumberAnimation { duration: 100 * ov.animMs; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 100 * ov.animMs; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: 100 * ov.animMs; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: 100 * ov.animMs; easing.type: Easing.OutCubic } }
    }

    // ---- layout picker -------------------------------------------------------------

    Rectangle {
        id: pickerPanel
        visible: ov.mode === "picker"
        anchors.horizontalCenter: parent.horizontalCenter
        y: 24
        width: pickerColumn.implicitWidth + 32
        height: pickerColumn.implicitHeight + 28
        radius: 12
        color: ov.surface
        border.color: "#3a404c"
        Accessible.role: Accessible.Grouping
        Accessible.name: "Snap layouts"

        MouseArea { anchors.fill: parent } // clicks on the panel's padding don't dismiss

        Column {
            id: pickerColumn
            anchors.centerIn: parent
            spacing: 10

            Text {
                text: "Snap layouts   ·   arrows, Tab or 1–9 to choose, Enter to snap, Esc to close"
                color: ov.subtleText
                font.pixelSize: 12
            }

            Grid {
                columns: Math.min(4, ov.layouts.length)
                spacing: 10
                Accessible.role: Accessible.Table

                Repeater {
                    model: ov.layouts
                    delegate: Rectangle {
                        id: mini
                        required property var modelData
                        required property int index
                        readonly property int layoutIndex: index
                        readonly property real aspect: {
                            const wa = ov.engine.workAreaRect(ov.engine.outputs.get(ov.outputName))
                            return wa ? wa.h / wa.w : 0.6
                        }
                        width: 112
                        height: Math.round(112 * aspect)
                        radius: 6
                        color: "#15171c"
                        border.width: ov.li === layoutIndex ? 2 : 0
                        border.color: ov.accent

                        Repeater {
                            model: mini.modelData.zones
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                readonly property bool selected: ov.li === mini.layoutIndex && ov.zi === index
                                x: 3 + modelData.x * (mini.width - 6) + 1
                                y: 3 + modelData.y * (mini.height - 6) + 1
                                width: modelData.w * (mini.width - 6) - 2
                                height: modelData.h * (mini.height - 6) - 2
                                radius: 3
                                color: selected ? ov.accent : (hover.containsMouse ? "#5d6576" : ov.neutral)
                                Accessible.role: Accessible.Button
                                Accessible.name: `${mini.modelData.name}, ${Layouts.zoneName(modelData)}, zone ${index + 1} of ${mini.modelData.zones.length}`
                                MouseArea {
                                    id: hover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onEntered: { ov.li = mini.layoutIndex; ov.zi = parent.index }
                                    onClicked: { ov.li = mini.layoutIndex; ov.zi = parent.index; ov.commitPicker() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- Fill Assist ---------------------------------------------------------------

    Rectangle {
        id: fillPanel
        visible: ov.mode === "fill" && ov.fill !== null
        x: ov.fill ? ov.fill.rect.x + 8 : 0
        y: ov.fill ? ov.fill.rect.y + 8 : 0
        width: ov.fill ? ov.fill.rect.w - 16 : 0
        height: ov.fill ? ov.fill.rect.h - 16 : 0
        radius: 12
        color: Qt.rgba(0.125, 0.137, 0.169, 0.94)
        border.width: 2
        border.color: ov.accent
        Accessible.role: Accessible.Dialog
        Accessible.name: ov.fill ? `Choose a window for the ${ov.fill.position}, ${ov.candidates.length} options` : ""

        MouseArea { anchors.fill: parent }

        Text {
            id: fillTitle
            x: 20
            y: 16
            width: parent.width - 40
            text: ov.fill ? `Choose a window for the ${ov.fill.position}` : ""
            color: ov.textColor
            font.pixelSize: 16
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Text {
            x: 20
            anchors.top: fillTitle.bottom
            anchors.topMargin: 4
            text: "Arrows and Enter to choose · Esc to skip"
            color: ov.subtleText
            font.pixelSize: 12
        }

        Flickable {
            x: 16
            y: 64
            width: parent.width - 32
            height: parent.height - 80
            contentHeight: candidateGrid.implicitHeight
            clip: true

            Grid {
                id: candidateGrid
                width: parent.width
                columns: Math.max(1, Math.floor((width + 10) / 170))
                spacing: 10

                Repeater {
                    model: ov.candidates
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool current: ov.ci === index
                        width: 160
                        height: 120
                        radius: 4
                        color: cardHover.containsMouse ? "#323845" : "#272b34"
                        border.width: current ? 2 : 0
                        border.color: ov.accent
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.title

                        IconImage {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 16
                            implicitSize: 48
                            source: {
                                // Re-evaluate once desktop entries finish loading.
                                const loaded = DesktopEntries.applications.values.length
                                const entry = DesktopEntries.heuristicLookup(modelData.appId)
                                const icon = entry && entry.icon ? entry.icon : modelData.appId
                                if (icon.startsWith("/")) return "file://" + icon // snaps use file paths
                                return Quickshell.iconPath(icon, "application-x-executable")
                            }
                        }
                        Text {
                            x: 8
                            y: 76
                            width: parent.width - 16
                            text: modelData.title
                            color: ov.textColor
                            font.pixelSize: 12
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.Wrap
                            horizontalAlignment: Text.AlignHCenter
                        }
                        MouseArea {
                            id: cardHover
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: ov.ci = parent.index
                            onClicked: ov.chooseCandidate(parent.index)
                        }
                    }
                }
            }
        }
    }
}

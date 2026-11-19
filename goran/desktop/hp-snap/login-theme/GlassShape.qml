// HP-OS liquid glass on the login screen: the desktop's own Liquid Glass lens (LiquidLens.frag, the same shader as
// hp-snap's IrisLiquidLens). What lies behind it bends toward the rim, with a little dispersion, and a light rim
// catches the light from the top left. It reads the screen behind it from the nearest parent that offers a
// glassBackdrop (the login style's background); it brightens a little on hover and when pressed.
import QtQuick 2.15
import QtQuick.Window

Item {
    id: glass
    property real radius: height / 2
    property real d: 1
    property bool lit: false
    property bool pressed: false
    // Kept so older settings and callers still load; the lens has one look.
    property string look: "clear"
    property real sheenDepth: 0.44
    property real sheenStrength: 1
    // 0 the clear lens; 1 frosted like HP-OS's thick glass: a milkier pane with a softer rim.
    property real frost: 1

    // Or given directly: the picture to bend, and the item whose coordinates it is drawn in.
    property Item backdropItem: null
    property Item hostItem: null

    readonly property Item host: {
        if (glass.hostItem) return glass.hostItem
        for (let p = glass.parent; p; p = p.parent)
            if (p.glassBackdrop !== undefined) return p
        return null
    }
    readonly property Item texture: glass.backdropItem ? glass.backdropItem : glass.host ? glass.host.glassBackdrop : null
    property real boost: glass.pressed ? 1 : glass.lit ? 0.6 : 0
    Behavior on boost { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    // Where it is on the screen, followed through every parent's movement.
    readonly property point scenePos: {
        for (let it = glass; it && it !== glass.host; it = it.parent) { void it.x; void it.y; void it.scale }
        if (!glass.host || !glass.visible) return Qt.point(0, 0)
        const p = glass.mapToItem(glass.host, 0, 0)
        return p ? Qt.point(p.x, p.y) : Qt.point(0, 0)
    }

    ShaderEffect {
        id: lens
        anchors.fill: parent
        visible: !!glass.texture
        fragmentShader: "LiquidLens.qsb"
        property Item backdrop: glass.texture
        property size itemSize: Qt.size(lens.width, lens.height)
        property rect sceneRect: Qt.rect(glass.scenePos.x, glass.scenePos.y, lens.width, lens.height)
        property size sceneSize: Qt.size(glass.host ? glass.host.width : 1, glass.host ? glass.host.height : 1)
        property real radius: Math.min(glass.radius, Math.min(lens.width, lens.height) / 2)
        property real bezel: Math.min(Math.min(lens.width, lens.height) * 0.28, 16 * glass.d)
        property real refraction: 0.75 + 0.25 * glass.boost
        property real pixelRatio: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
        property real presence: 1
        property real highlight: (1.05 - 0.35 * glass.frost) + 0.35 * glass.boost
        property vector4d crop: Qt.vector4d(0, 0, 1, 1)
        property vector4d tint: Qt.vector4d(1, 1, 1, 0.06 + 0.10 * glass.frost + 0.08 * glass.boost)
    }
    // Without a background to bend (another login style), a plain clear pane.
    Rectangle {
        visible: !glass.texture
        anchors.fill: parent
        radius: glass.radius
        color: Qt.rgba(1, 1, 1, 0.10 + 0.08 * glass.boost)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.3)
    }
}

// The look of HP-OS's windows that run outside the desktop shell (App Installer, Software Update): light or dark and
// the accent colour, as the desktop has them right now, and HP-OS's glass. A change while the window is open (dark
// mode at sunset, a new accent in Settings) shows straight away.
//
// It reads what the desktop already writes down: appearance-mode (light or dark), the accent the shell hands to niri
// (config.d/46-accent.kdl, empty when "one accent" is off: then HP-OS blue, as the shell's own controls use) and the
// glass settings in config.json. Nothing missing or unreadable stops a window: it falls back to HP-OS's defaults.
// For trying it out: HP_OS_LOOK_MODE=light|dark, HP_OS_LOOK_ACCENT=#rrggbb, HP_OS_LOOK_GLASS=0|1.
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: look
    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: Quickshell.env("INIR_STATE_DIR")
        || ((Quickshell.env("XDG_STATE_HOME") || look.home + "/.local/state") + "/hp-os")
    readonly property string configDir: Quickshell.env("INIR_CONFIG_DIR")
        || ((Quickshell.env("XDG_CONFIG_HOME") || look.home + "/.config") + "/hp-os")
    readonly property string niriDir: Quickshell.env("INIR_NIRI_CONFIG_DIR") || look.configDir + "/niri"

    // ── What the desktop says ──
    property string modeText: ""
    property string accentText: ""
    property string blurText: ""
    property var preferences: ({})
    readonly property FileView modeFile: FileView {
        path: look.stateDir + "/appearance-mode"
        watchChanges: true; printErrors: false
        onFileChanged: this.reload()
        onLoaded: look.modeText = this.text().trim()
        onLoadFailed: look.modeText = ""
    }
    readonly property FileView accentFile: FileView {
        path: look.niriDir + "/config.d/46-accent.kdl"
        watchChanges: true; printErrors: false
        onFileChanged: this.reload()
        onLoaded: { const found = /active-color\s+"(#[0-9a-fA-F]{6})/.exec(this.text()); look.accentText = found ? found[1] : "" }
        onLoadFailed: look.accentText = ""
    }
    // Niri's blur, switched off for the whole desktop in Settings (a top-level `blur { off }`): then no glass here either.
    readonly property FileView blurFile: FileView {
        path: look.niriDir + "/config.d/80-layer-rules.kdl"
        watchChanges: true; printErrors: false
        onFileChanged: this.reload()
        onLoaded: look.blurText = this.text().replace(/\/\/[^\n]*/g, "")
        onLoadFailed: look.blurText = ""
    }
    readonly property FileView configFile: FileView {
        path: look.configDir + "/config.json"
        watchChanges: true; printErrors: false
        onFileChanged: this.reload()
        onLoaded: { try { look.preferences = JSON.parse(this.text()).hpos ?? ({}) } catch (error) {} }
    }

    // ── Light or dark, and the accent ──
    readonly property string modeOverride: Quickshell.env("HP_OS_LOOK_MODE") || ""
    readonly property bool dark: (look.modeOverride || look.modeText) === "dark"
    readonly property string accentOverride: Quickshell.env("HP_OS_LOOK_ACCENT") || ""
    readonly property color accent: /^#[0-9a-fA-F]{6}$/.test(look.accentOverride) ? look.accentOverride
        : look.accentText.length > 0 ? look.accentText : look.dark ? "#83baff" : "#0a59f7"
    // Words on the accent: white or near-black, whichever reads better on it (white below a luminance of 0.194,
    // where the two contrasts are equal). A name starting "on" and a capital reads as a signal handler.
    function luminance(c) {
        const part = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
        return 0.2126 * part(c.r) + 0.7152 * part(c.g) + 0.0722 * part(c.b)
    }
    readonly property color inkOnAccent: look.luminance(look.accent) < 0.194 ? "#ffffff" : "#101318"

    // ── HP-OS's colours (the shell's HposTokens) ──
    readonly property color surface: look.dark ? "#242528" : "#ffffff"
    readonly property color text: look.dark ? "#f1f3f5" : "#18212b"
    readonly property color secondary: look.dark ? "#b5bac2" : "#596573"
    readonly property color tertiary: look.dark ? Qt.rgba(0.95, 0.95, 0.96, 0.5) : Qt.rgba(0.09, 0.13, 0.17, 0.48)
    // Groups, fields and plain buttons: a faint layer of the ink, as on the desktop's glass.
    function ink(alpha) { return look.dark ? Qt.rgba(1, 1, 1, alpha) : Qt.rgba(0.094, 0.129, 0.169, alpha * 0.62) }
    readonly property color fillQuiet: look.ink(0.08)
    readonly property color fill: look.ink(0.12)
    readonly property color fillHover: look.ink(0.18)
    readonly property color fillActive: look.ink(0.26)
    function tint(c, alpha) { return Qt.rgba(c.r, c.g, c.b, alpha) }
    readonly property color accentSoft: look.tint(look.accent, look.dark ? 0.2 : 0.13)
    // Something to stop and read (a warning): warm, and readable in either mode.
    readonly property color caution: look.dark ? "#ffb4ab" : "#b3261e"
    readonly property color cautionSoft: look.dark ? Qt.rgba(1, 0.71, 0.67, 0.14) : Qt.rgba(0.85, 0.2, 0.12, 0.08)
    readonly property color success: look.dark ? "#4fd69c" : "#14866d"

    // ── Glass: the desktop behind, blurred by niri, under a tint of the surface ──
    readonly property string glassOverride: Quickshell.env("HP_OS_LOOK_GLASS") || ""
    readonly property string material: String(look.preferences.material ?? "frosted")
    readonly property bool blurOff: /(^|\n)\s*blur\s*\{[^}]*\boff\b/.test(look.blurText)
    readonly property bool glass: look.glassOverride.length > 0 ? look.glassOverride === "1"
        : !(look.preferences.reducedTransparency === true || look.preferences.quality === "performance"
            || look.material === "solid" || look.blurOff)
    // The shell's recipe for a dialog (ULTRA_THICK), lighter for Liquid Glass, which is clear.
    readonly property real intensity: Math.max(0.5, Math.min(1.5, Number(look.preferences.materialIntensity ?? 1) || 1))
    readonly property real glassAlpha: Math.min(1, 0.96 * look.intensity) * (look.material === "liquid" ? 0.55 : 1)
    // These windows are read, not glanced at: never thinner than this, or text over a busy or bright desktop (a light
    // wallpaper behind a dark window) gets hard to read.
    readonly property real readable: look.dark ? 0.74 : 0.6
    readonly property color body: look.glass ? look.tint(look.surface, Math.max(look.readable, look.glassAlpha)) : look.surface
    // The glass's edge: lit, so the window reads as a pane in front of what it blurs.
    readonly property color rim: look.dark ? Qt.rgba(1, 1, 1, look.glass ? 0.16 : 0.08) : Qt.rgba(1, 1, 1, look.glass ? 0.7 : 0)

    readonly property string font: String(look.preferences.fontFamily || "HarmonyOS Sans")
    readonly property int radius: 16
}

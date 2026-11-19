// HP-OS login, Studio: the Lens login's sign-in, rearranged. theme.conf irisStudio picks the arrangement:
//   horizon    the picture sharp, the date over a slim clock at the top, people along the bottom (macOS-like)
//   card       the picture soft, one frosted glass card in the middle holding the time, people and password
//   editorial  the picture sharp, a large slim clock stacked on the left, sign-in on the right (HarmonyOS-like)
import QtQuick 2.15
import QtQuick.Effects
import "."

LoginSurface {
    id: root
    field: profileChosen ? entry.input : null

    property bool profileChosen: false

    readonly property string studio: String(config.irisStudio || "horizon")
    readonly property bool sharp: root.studio !== "card"
    readonly property bool cardShown: root.studio === "card"
    // Where the people and the password sit (their centre), and the card around them.
    readonly property real peopleCentreX: root.studio === "editorial" ? Math.round(root.width * 0.74) : Math.round(root.width / 2)
    readonly property real peopleTopY: root.studio === "editorial" ? Math.round(root.height * 0.42)
        : root.studio === "card" ? Math.round(root.height * 0.56) : Math.round(root.height * 0.74)

    // 0 is the row of people, 1 the password; everything on the way between is drawn from this one value.
    property real stage: profileChosen ? 1 : 0
    Behavior on stage { NumberAnimation { duration: 560; easing.type: Easing.BezierSpline; easing.bezierCurve: root.expressive } }
    readonly property real passwordShown: Math.max(0, Math.min(1, (root.stage - 0.3) / 0.7))
    readonly property real peopleShown: Math.max(0, 1 - root.stage * 1.8)
    property var flyingFace: null
    property real flyFromX: 0
    property real flyFromY: 0
    property real flyFromSize: 0
    readonly property bool flying: root.flyingFace !== null && root.stage > 0 && root.stage < 1
    function flyFrom(face) {
        if (!face || !face.visible) { root.flyingFace = null; return }
        const middle = face.mapToItem(root, face.width / 2, face.height / 2)
        root.flyFromX = middle.x
        root.flyFromY = middle.y
        root.flyFromSize = face.width
        root.flyingFace = face
    }

    function chooseProfile(index) {
        if (root.core.signingIn) return
        const tile = profileTiles.itemAt(index)
        root.flyFrom(tile ? tile.face : null)
        root.core.addedChosen = false
        root.core.userIndex = index
        root.core.failed = false
        root.core.notice = ""
        entry.input.text = ""
        root.profileChosen = true
        entry.input.forceActiveFocus()
    }
    function showProfiles() {
        if (root.core.signingIn) return
        entry.input.text = ""
        root.core.failed = false
        root.core.notice = ""
        root.profileChosen = false
        profileList.forceActiveFocus()
    }

    // HP-OS: Add user runs as its own window and leaves a note here saying who it created.
    function chooseAdded(fromTile) {
        if (root.core.signingIn) return
        root.flyFrom(fromTile === true ? addedTile.face : null)
        root.core.addedChosen = true
        root.core.failed = false
        root.core.notice = ""
        entry.input.text = ""
        root.profileChosen = true
        entry.input.forceActiveFocus()
    }
    property bool awaitingNewAccount: false
    Loader {
        id: newAccount
        active: root.awaitingNewAccount
        onLoaded: {
            const login = String(item.login || "")
            const name = String(item.name || login)
            const icon = String(item.icon || "")
            const signIn = String(item.signIn || "")
            root.awaitingNewAccount = false
            if (login.length === 0) { root.forceActiveFocus(); return }
            root.core.addedLogin = login
            root.core.addedName = name
            root.core.addedIcon = icon
            root.chooseAdded()
            // They just chose this password in Add user: no need to ask for it again.
            if (signIn.length > 0) autoSignIn.source = signIn + "?" + Date.now()
        }
    }
    Loader {
        id: autoSignIn
        onLoaded: {
            entry.input.text = String(item.password || "")
            root.core.signIn()
            entry.input.text = ""
            Qt.callLater(() => autoSignIn.source = "")
        }
    }
    Timer {
        interval: 800; repeat: true
        running: root.awaitingNewAccount
        onTriggered: newAccount.source = "file:///var/lib/sddm/.local/state/hp-os-add-user/account.qml?" + Date.now()
    }

    readonly property color ink: "#ffffff"
    readonly property color inkSoft: Qt.rgba(1, 1, 1, 0.74)
    readonly property color inkFaint: Qt.rgba(1, 1, 1, 0.56)

    // One person in the row: rises into place in turn, and answers the pointer.
    component Tile: FocusScope {
        id: tile
        property string shownName: ""
        property string shownIcon: ""
        property string shownLogin: ""
        property int order: 0
        property alias face: tileFace
        signal chosen()
        readonly property real appear: Math.max(0, Math.min(1, root.entrance * 1.7 - tile.order * 0.14))
        readonly property bool lifted: tileHit.containsMouse || tile.activeFocus
        width: root.px(160); height: root.px(190)
        opacity: tile.appear
        transform: Translate { y: Math.round((1 - tile.appear) * 22 * root.d) }
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: tile.shownName
        Accessible.onPressAction: tile.chosen()
        Keys.onReturnPressed: tile.chosen()
        Keys.onEnterPressed: tile.chosen()
        Keys.onSpacePressed: tile.chosen()
        Rectangle {
            anchors.fill: parent; radius: root.px(24)
            color: Qt.rgba(1, 1, 1, tileHit.pressed ? 0.18 : tile.lifted ? 0.12 : 0)
            border.width: 2
            border.color: tile.activeFocus ? root.core.accent : "transparent"
            scale: tileHit.pressed ? 0.97 : 1
            Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on border.color { ColorAnimation { duration: 180 } }
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }
        Column {
            anchors { top: parent.top; topMargin: root.px(14); horizontalCenter: parent.horizontalCenter }
            spacing: root.px(14)
            LoginAvatar {
                id: tileFace
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.px(88); height: width
                account: tile.shownLogin
                icon: tile.shownIcon
                name: tile.shownName
                fontFamily: root.core.fontMain
                opacity: root.flyingFace === tileFace && root.stage > 0 ? 0 : 1
                scale: tileHit.pressed ? 0.93 : tile.lifted ? 1.08 : 1
                Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
            }
            LoginText {
                width: root.px(150)
                text: tile.shownName
                color: root.ink
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                font.family: root.core.fontMain
                font.pixelSize: root.type(18)
                font.weight: Font.DemiBold
            }
        }
        MouseArea {
            id: tileHit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.chosen()
        }
    }
    component Corner: LoginAction {
        d: root.d
        size: root.px(42)
        fontSize: root.type(16)
        fontFamily: root.core.fontMain
        symbolFont: root.core.symbolFont
        ink: root.ink
    }

    // Everything behind the sign-in: the glass bends it (glassBackdrop, GlassShape).
    Item {
        id: backdropLayer
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: root.core.surface }
        // HP-OS: the device owner's wallpaper while choosing who signs in, the chosen person's own once picked,
        // fading between them (each account shares its wallpaper as it signs in and out: hp-os-login-wallpaper).
        // The theme's day or night picture stands in for any that hasn't been shared yet.
        Item {
            id: picture
            anchors.fill: parent
            visible: false
            readonly property string folder: String(config.irisAccountPictures || "/var/lib/hp-os/login-wallpapers")
            property string shownLogin: ""
            Connections {
                target: root
                function onProfileChosenChanged() {
                    const login = String(root.core.userLogin || "")
                    if (root.profileChosen && /^[a-z_][a-z0-9_-]{0,31}$/.test(login)) picture.shownLogin = login
                }
            }
            Image {
                anchors.fill: parent
                source: root.core.picture
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(root.width, root.height)
                asynchronous: true
                cache: false
            }
            Image {
                id: ownerPicture
                anchors.fill: parent
                source: "file://" + picture.folder + "/default.jpg"
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(root.width, root.height)
                asynchronous: true
                cache: false
                opacity: status === Image.Ready ? 1 : 0
            }
            Image {
                id: accountPicture
                anchors.fill: parent
                source: picture.shownLogin.length > 0 ? "file://" + picture.folder + "/" + picture.shownLogin + ".jpg" : ""
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(root.width, root.height)
                asynchronous: true
                cache: false
                opacity: root.profileChosen && status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
            }
        }
        // Out of focus and dimmed, a little richer than the picture so it never reads grey; signing in brings it back.
        MultiEffect {
            anchors.fill: parent
            source: picture
            scale: 1.08 - 0.08 * root.release
            blurEnabled: !root.sharp
            blur: 1
            blurMax: Math.round(56 * (1 - root.release))
            saturation: 0.12 * (1 - root.release)
            brightness: -0.04 * (1 - root.release)
            opacity: Math.min(1, root.entrance * 2)
        }
        // HP-OS: the veil takes the scene's tint (irisVeilDay/Night): HP navy by day, so a bright picture
        // reads blue rather than grey, black at night.
        Rectangle { anchors.fill: parent; color: Qt.rgba(root.core.veil.r, root.core.veil.g, root.core.veil.b, ((root.sharp ? 0.12 : 0.36) + root.core.lift) * (1 - root.release)) }
        // With the picture sharp, a soft shade at the top and bottom keeps white type readable.
        Rectangle {
            visible: root.sharp
            anchors.fill: parent
            opacity: 1 - root.release
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, root.studio === "horizon" ? 0.34 : 0.10) }
                GradientStop { position: 0.32; color: "transparent" }
                GradientStop { position: 0.62; color: "transparent" }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.42) }
            }
        }
        Rectangle {
            visible: root.studio === "editorial"
            anchors.fill: parent
            opacity: 1 - root.release
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.42) }
                GradientStop { position: 0.5; color: "transparent" }
            }
        }
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
    readonly property Item glassBackdrop: backdropTexture

    // The card: one pane of glass holding everything.
    GlassShape {
        visible: root.cardShown && root.primary
        opacity: root.entrance * (1 - root.release)
        width: root.px(560); height: root.px(640)
        x: Math.round((root.width - width) / 2)
        y: Math.round(root.height * 0.5 - height / 2)
        radius: root.px(44)
        d: root.d
        look: "clear"
        sheenDepth: 0.1
        sheenStrength: 0.6
    }

    // ── The clock (plain type) ──
    Column {
        id: plainClock
        opacity: root.entrance * (1 - root.release)
        transform: Translate { y: -Math.round(12 * root.d * root.stage) }
        spacing: root.studio === "editorial" ? -Math.round(root.type(250) * 0.3) : root.px(4)
        x: root.studio === "editorial" ? root.px(110) : Math.round((root.width - width) / 2)
        y: root.studio === "editorial" ? Math.round(root.height * 0.5 - height / 2)
            : root.studio === "card" ? Math.round(root.height * 0.5 - root.px(640) / 2 + root.px(56))
            : Math.round(root.height * 0.085)
        LoginText {
            visible: root.studio !== "editorial"
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.core.weekday + ", " + root.core.dayMonth
            color: root.inkSoft
            font.family: root.core.fontMain
            font.pixelSize: root.type(root.studio === "card" ? 20 : 24)
            font.weight: Font.DemiBold
        }
        LoginText {
            visible: root.studio !== "editorial"
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.core.hours + ":" + root.core.minutes
            color: root.ink
            font.family: root.core.fontMain
            font.pixelSize: root.type(root.studio === "card" ? 96 : 150)
            font.weight: Font.Light
            font.features: ({ "tnum": 1 })
        }
        LoginText {
            visible: root.studio === "editorial"
            text: root.core.hours
            color: root.ink
            font.family: root.core.fontMain
            font.pixelSize: root.type(250)
            font.weight: Font.Light
            lineHeight: 0.82
            font.features: ({ "tnum": 1 })
        }
        LoginText {
            visible: root.studio === "editorial"
            text: root.core.minutes
            color: root.ink
            font.family: root.core.fontMain
            font.pixelSize: root.type(250)
            font.weight: Font.Light
            lineHeight: 0.82
            font.features: ({ "tnum": 1 })
        }
        LoginText {
            visible: root.studio === "editorial"
            topPadding: Math.round(root.type(250) * 0.3) + root.px(10)
            text: root.core.weekday + "\n" + root.core.dayMonth
            color: root.inkSoft
            font.family: root.core.fontMain
            font.pixelSize: root.type(26)
            font.weight: Font.Medium
            lineHeight: 1.15
        }
    }

    // ── Who, and the password ──
    Column {
        id: signIn
        visible: root.primary && root.stage > 0
        enabled: root.profileChosen
        x: root.peopleCentreX - Math.round(width / 2)
        y: root.peopleTopY + root.px(8)
        spacing: root.px(18)
        opacity: Math.max(0, Math.min(1, root.entrance * 1.3 - 0.3)) * (1 - root.release) * root.passwordShown
        transform: Translate { y: Math.round((1 - root.entrance) * 28 * root.d + root.release * 20 * root.d + (1 - root.passwordShown) * 26 * root.d) }

        Row {
            id: who
            visible: root.core.showAvatar || root.core.showName
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: root.px(12)
            LoginAvatar {
                id: whoAvatar
                visible: root.core.showAvatar
                opacity: root.flying ? 0 : 1
                anchors.verticalCenter: parent.verticalCenter
                width: root.px(38)
                height: width
                account: root.core.userLogin
                icon: root.core.userIcon
                name: root.core.userName
                fontFamily: root.core.fontMain
            }
            LoginText {
                visible: root.core.showName
                anchors.verticalCenter: parent.verticalCenter
                text: root.core.userName
                color: root.ink
                font.family: root.core.fontMain
                font.pixelSize: root.type(20)
                font.weight: Font.DemiBold
            }
            MSymbol {
                visible: false
                anchors.verticalCenter: parent.verticalCenter
                text: "unfold_more"
                symFont: root.core.symbolFont
                iconSize: root.px(20)
                iconColor: root.inkSoft
            }
        }

        Item {
            id: lozenge
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.px(root.studio === "card" ? 420 : 460)
            height: root.px(root.studio === "horizon" ? 52 : 60)
            scale: 0.92 + 0.08 * root.passwordShown
            transform: Translate { x: root.shakeX }
            GlassShape {
                anchors.fill: parent
                d: root.d
                look: String(config.irisGlassLook || "clear")
                lit: entry.input.activeFocus
            }
            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: "transparent"
                border.width: Math.max(1, root.px(2))
                border.color: root.core.failed ? root.core.danger : root.core.accentInk
                opacity: entry.input.activeFocus || root.core.failed ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on border.color { ColorAnimation { duration: 200 } }
            }
            LoginEntry {
                id: entry
                anchors.fill: parent
                anchors.leftMargin: root.px(64)
                anchors.rightMargin: root.px(64)
                d: root.d
                // HP-OS: plain round dots in soft white, like the HP-OS lock screen (HarmonyOS/macOS),
                // not Material's expressive shapes.
                marks: "dots"
                centred: true
                busy: root.core.signingIn
                markColour: Qt.rgba(1, 1, 1, 0.92)
                markSize: root.px(13)
                markGap: root.px(11)
                caretColour: root.core.accentInk
                caretHeight: root.px(26)
                placeholder: root.core.text.password
                placeholderColour: root.inkFaint
                fontFamily: root.core.fontMain
                fontSize: root.type(18)
                onSubmitted: root.core.signIn()
                onEdited: root.core.typed()
            }
            LoginSubmit {
                anchors.right: parent.right
                anchors.rightMargin: root.px(8)
                anchors.verticalCenter: parent.verticalCenter
                width: root.px(48)
                height: width
                d: root.d
                shown: entry.count > 0
                busy: root.core.signingIn
                fill: root.core.accent
                ink: root.core.onAccent
                symbolFont: root.core.symbolFont
                onActivated: root.core.signIn()
            }
        }
        LoginText {
            id: hintLine
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.core.showHint
            width: Math.min(implicitWidth, root.px(560))
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            // Keeps its last words while fading away.
            property string words: " "
            readonly property string wanted: root.core.hint
            onWantedChanged: if (wanted.length > 0) words = wanted
            opacity: root.core.hint.length > 0 ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            text: hintLine.words
            font.underline: root.core.offerRecovery
            MouseArea {
                anchors.fill: parent
                enabled: root.core.offerRecovery
                cursorShape: Qt.PointingHandCursor
                onClicked: root.core.openRecovery()
            }
            color: root.core.hintIsWarning ? root.core.danger : root.core.highlight
            font.family: root.core.fontMain
            font.pixelSize: root.type(15)
            font.weight: Font.Medium
        }
    }
    // Choose an account first; credentials are never carried between accounts.
    Flickable {
        id: profileList
        visible: root.primary && root.stage < 1
        enabled: !root.profileChosen
        opacity: root.peopleShown
        scale: 1 - 0.05 * root.stage
        x: root.peopleCentreX - Math.round(width / 2)
        y: root.peopleTopY
        width: Math.min(profileRow.width, root.width - root.px(80))
        height: root.px(200)
        contentWidth: profileRow.width
        contentHeight: height
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        focus: true
        Keys.onReturnPressed: root.chooseProfile(root.core.userIndex)
        Keys.onEnterPressed: root.chooseProfile(root.core.userIndex)
        Row {
            id: profileRow
            spacing: root.px(24)
            // The account Add user just made: SDDM lists it from the next start of this screen.
            Tile {
                id: addedTile
                visible: root.core.addedLogin.length > 0
                shownName: root.core.addedName
                shownIcon: root.core.addedIcon
                shownLogin: root.core.addedLogin
                onChosen: root.chooseAdded(true)
            }
            Repeater {
                id: profileTiles
                model: userModel
                delegate: Tile {
                    required property int index
                    order: index + (addedTile.visible ? 1 : 0)
                    shownName: root.core.modelText(userModel, index, root.core.realNameRole) || root.core.modelText(userModel, index, root.core.nameRole)
                    shownIcon: root.core.modelText(userModel, index, root.core.iconRole)
                    shownLogin: root.core.modelText(userModel, index, root.core.nameRole)
                    onChosen: root.chooseProfile(index)
                }
            }
        }
    }
    // The chosen person's picture, travelling between their tile and its place above the password.
    LoginAvatar {
        id: flyer
        z: 5
        visible: root.flying
        // Measured afresh every frame: its landing place is itself still rising into position.
        function landing() { return whoAvatar.mapToItem(root, whoAvatar.width / 2, whoAvatar.height / 2) }
        width: root.flyFromSize + (whoAvatar.width - root.flyFromSize) * root.stage
        height: width
        x: Math.round(root.flyFromX + (flyer.landing().x - root.flyFromX) * root.stage - width / 2)
        y: Math.round(root.flyFromY + (flyer.landing().y - root.flyFromY) * root.stage - height / 2)
        account: root.core.userLogin
        icon: root.core.userIcon
        name: root.core.userName
        fontFamily: root.core.fontMain
    }
    LoginAction {
        visible: root.primary && root.stage > 0
        enabled: root.profileChosen && !root.core.signingIn
        opacity: root.passwordShown * (1 - root.release)
        x: root.peopleCentreX - Math.round(width / 2)
        y: signIn.y + signIn.height + root.px(8) + Math.round((1 - root.passwordShown) * 26 * root.d)
        d: root.d
        glyph: "arrow_back"
        label: "Other users"
        fontFamily: root.core.fontMain
        symbolFont: root.core.symbolFont
        ink: root.ink
        onActivated: root.showProfiles()
    }

    // ── Corners: session and layout left, power right ──
    Row {
        visible: root.primary
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: root.px(40)
        opacity: root.entrance * (1 - root.release)
        spacing: root.px(10)
        // HP-OS: Add user lives with the other corner actions, as a glass pill.
        Corner {
            enabled: !root.core.signingIn
            glyph: "person_add"; label: "Add user"
            onActivated: {
                if (Qt.openUrlExternally("hpos-add-user:")) {
                    root.awaitingNewAccount = true
                } else {
                    root.core.notice = "User setup could not open. Try again."
                    root.profileChosen = true
                }
            }
        }
        Corner { visible: root.core.manySessions; glyph: "desktop_windows"; label: root.core.sessionName; onActivated: root.core.nextSession() }
        Corner { visible: root.core.manyLayouts; glyph: "keyboard"; label: root.core.layoutName; onActivated: root.core.nextLayout() }
    }
    Row {
        visible: root.primary
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: root.px(40)
        opacity: root.entrance * (1 - root.release)
        spacing: root.px(10)
        Corner { visible: sddm.canSuspend; glyph: "bedtime"; onActivated: sddm.suspend() }
        Corner { visible: sddm.canReboot; glyph: "restart_alt"; onActivated: sddm.reboot() }
        Corner { visible: sddm.canPowerOff; glyph: "power_settings_new"; onActivated: sddm.powerOff() }
    }
}

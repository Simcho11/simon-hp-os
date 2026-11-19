// The person: their face in a circle, or their initial when there is no face.
import QtQuick 2.15
import QtQuick.Effects

Item {
    id: root
    property string icon: ""
    // The account's login name: its picture is the one kept by AccountsService, which Settings can change.
    property string account: ""
    property string name: ""
    property string fontFamily: "Inter"
    property color fill: Qt.rgba(1, 1, 1, 0.2)
    property color ink: "#ffffff"

    property int sourceIndex: 0
    // HP-OS: SDDM's stock grey silhouette counts as "no face", so people get their initial on HP blue.
    readonly property bool stockFace: root.icon.indexOf("/sddm/faces/") >= 0 || root.icon.indexOf(".face.icon") >= 0
    readonly property var sources: [root.account ? "file:///var/lib/AccountsService/icons/" + root.account : "",
        root.stockFace ? "" : root.icon].filter(s => s.length > 0)
    onIconChanged: root.sourceIndex = 0
    onAccountChanged: root.sourceIndex = 0
    // The circle is drawn large and scaled down, so its edge stays smooth at any size or display scale.
    readonly property size crisp: Qt.size(512, 512)

    Item {
        id: face
        anchors.fill: parent
        layer.enabled: true
        layer.textureSize: root.crisp
        layer.smooth: true
        layer.mipmap: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "#4f8dff" }
                GradientStop { position: 1; color: "#0a3fc0" }
            }
        }
        Image {
            id: image
            anchors.fill: parent
            source: root.sources[root.sourceIndex] || ""
            sourceSize: root.crisp
            smooth: true
            fillMode: Image.PreserveAspectCrop
            cache: false
            mipmap: true
            asynchronous: true
            onStatusChanged: if (status === Image.Error && root.sourceIndex + 1 < root.sources.length) root.sourceIndex++
        }
    }
    LoginText {
        anchors.centerIn: parent
        visible: image.status !== Image.Ready
        text: (root.name || "?").charAt(0).toUpperCase()
        color: root.ink
        font.family: root.fontFamily
        font.pixelSize: Math.round(root.height * 0.42)
        font.weight: Font.DemiBold
    }
    Item {
        id: mask
        anchors.fill: parent
        layer.enabled: true
        layer.textureSize: root.crisp
        layer.smooth: true
        layer.mipmap: true
        visible: false
        Rectangle { anchors.fill: parent; radius: width / 2; antialiasing: true }
    }
    // A hairline rim finishes the edge against the blurred picture behind it.
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        antialiasing: true
        border.width: Math.max(1, Math.round(root.width / 88))
        border.color: Qt.rgba(1, 1, 1, 0.22)
    }
}

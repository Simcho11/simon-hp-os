// An administrator's password, as HP-OS's own password prompt asks for it: a pill, outlined in the accent while typing.
import QtQuick

FocusScope {
    id: field
    required property var look
    property alias text: input.text
    property string placeholder: "Administrator password"
    signal accepted()
    implicitWidth: 380
    implicitHeight: 48

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: input.activeFocus ? field.look.fill : field.look.fillQuiet
        border.width: input.activeFocus ? 1.5 : 0
        border.color: field.look.tint(field.look.accent, 0.7)
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    TextInput {
        id: input
        focus: true
        anchors { fill: parent; leftMargin: 24; rightMargin: 24 }
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        color: field.look.text
        selectionColor: field.look.accent
        selectedTextColor: field.look.inkOnAccent
        font.family: field.look.font
        font.pixelSize: 17
        echoMode: TextInput.Password
        passwordCharacter: "●"
        clip: true
        maximumLength: 256
        onAccepted: field.accepted()
    }
    Text {
        anchors.centerIn: parent
        visible: input.text.length === 0
        text: field.placeholder
        color: field.look.tertiary
        font.family: field.look.font
        font.pixelSize: 16
    }
}

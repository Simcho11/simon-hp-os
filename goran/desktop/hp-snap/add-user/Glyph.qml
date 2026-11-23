// A small symbol, drawn (no icon font needed): Material Symbols' shapes (Apache 2.0) on a 24-unit grid.
import QtQuick
import QtQuick.Shapes

Item {
    id: glyph
    property string name: "check"
    property color color: "black"
    property real size: 24
    implicitWidth: glyph.size
    implicitHeight: glyph.size
    readonly property var paths: ({
        check: "M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z",
        download: "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z",
        restart: "M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z",
        alert: "M11 15h2v2h-2zm0-10h2v8h-2z",
        lock: "M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z",
        box: "M20 7.5L12 3 4 7.5v9l8 4.5 8-4.5zM12 5.3l5.2 2.9-2.1 1.2-5.2-2.9zm-1 13.1l-5-2.8V9.8l5 2.8zm1-7.5L6.8 8.2l2.1-1.2 5.2 2.9zm6 4.7l-5 2.8v-5.8l5-2.8z"
    })
    Shape {
        width: 24; height: 24
        anchors.centerIn: parent
        scale: glyph.size / 24
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: glyph.color
            strokeWidth: -1
            strokeColor: "transparent"
            PathSvg { path: glyph.paths[glyph.name] ?? glyph.paths.check }
        }
    }
}

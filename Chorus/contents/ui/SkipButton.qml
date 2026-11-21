import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3

// Previous and next track buttons
PC3.ToolButton {
    id: btn

    property bool forward: true
    property real size: 24
    property color glyphColor: "white"

    hoverEnabled: true
    Layout.preferredWidth: size
    Layout.preferredHeight: size

    background: Rectangle {
        anchors.centerIn: parent
        width: btn.size * 0.88
        height: width
        radius: Math.max(4, Math.round(width * 0.22))
        color: Qt.alpha(Kirigami.Theme.highlightColor,
                        btn.down ? 0.34 : (btn.hovered && btn.enabled ? 0.20 : 0.0))
        border.width: (btn.hovered || btn.down) && btn.enabled ? 1 : 0
        border.color: Qt.alpha(Kirigami.Theme.highlightColor, btn.down ? 0.50 : 0.32)
        Behavior on color { ColorAnimation { duration: 140 } }
    }

    contentItem: Item {
        implicitWidth: btn.size
        implicitHeight: btn.size
        opacity: btn.enabled ? 1.0 : 0.35
        scale: btn.down ? 0.90 : (btn.hovered && btn.enabled ? 1.05 : 1.0)
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        readonly property real g: btn.size * 0.34
        readonly property real cx: width / 2
        readonly property real cy: height / 2

        // end bar
        Rectangle {
            width: Math.max(1.5, btn.size * 0.06)
            height: parent.g * 1.6
            radius: width / 2
            color: btn.glyphColor
            y: parent.cy - height / 2
            x: btn.forward ? parent.cx + parent.g * 0.55
                           : parent.cx - parent.g * 0.55 - width
        }

        // single triangle
        Canvas {
            id: tri
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.fillStyle = btn.glyphColor;
                var g = parent.g;
                var cx = parent.cx, cy = parent.cy;
                ctx.beginPath();
                if (btn.forward) {
                    ctx.moveTo(cx - g * 0.75, cy - g * 0.8);
                    ctx.lineTo(cx - g * 0.75, cy + g * 0.8);
                    ctx.lineTo(cx + g * 0.45, cy);
                } else {
                    ctx.moveTo(cx + g * 0.75, cy - g * 0.8);
                    ctx.lineTo(cx + g * 0.75, cy + g * 0.8);
                    ctx.lineTo(cx - g * 0.45, cy);
                }
                ctx.closePath();
                ctx.fill();
            }
            Connections {
                target: btn
                function onGlyphColorChanged() { tri.requestPaint(); }
                function onSizeChanged() { tri.requestPaint(); }
            }
        }
    }
}
